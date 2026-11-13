// Package reconcile keeps the upload history in step with the bucket: a file
// this tool sent whose object is no longer there is taken out of the history.
//
// It only looks at the finished files the history records for the configured
// bucket, never at other objects of the bucket, and it only removes what the
// bucket positively reported absent: when a listing fails or is cut short,
// nothing is removed for the keys it did not cover. It never blocks uploads;
// it runs on its own goroutine, started by Run.
package reconcile

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"

	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

// History is the part of the upload queue the reconciliation reads and changes.
type History interface {
	// FinishedFiles returns the finished files of uploads of bucket that are at
	// rest, as they are when it is called.
	FinishedFiles(bucket string) ([]queue.FinishedFile, error)
	// ForgetMissing removes the files from the history, leaving alone any that
	// changed or whose upload is not at rest any more.
	ForgetMissing(bucket string, missing []queue.FinishedFile) (removed int, err error)
}

// Lister lists the keys of the bucket in s under a prefix.
type Lister interface {
	// ListKeys calls visit with every key under prefix. A non-nil error means
	// the listing is incomplete.
	ListKeys(ctx context.Context, s uploader.Settings, prefix string, visit func(key string)) error
}

// Reconciler runs reconciliation passes in the background.
type Reconciler struct {
	history History
	lister  Lister
	log     *logging.Logger
	wake    chan struct{} // capacity 1: triggers that arrive during a pass collapse into one

	mu       sync.Mutex
	settings uploader.Settings
	hasConf  bool
}

// New returns a Reconciler. It does nothing until Run is called and Configure
// has given it settings.
func New(h History, l Lister, log *logging.Logger) *Reconciler {
	return &Reconciler{history: h, lister: l, log: log, wake: make(chan struct{}, 1)}
}

// Configure sets the settings later passes use and asks for a pass. It never
// blocks.
func (r *Reconciler) Configure(s uploader.Settings) {
	r.mu.Lock()
	r.settings, r.hasConf = s, true
	r.mu.Unlock()
	r.Trigger()
}

// Trigger asks for a pass. Requests made while a pass runs, or before it
// starts, collapse into a single pass. It never blocks.
func (r *Reconciler) Trigger() {
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

// Run makes a pass for each trigger until ctx ends.
func (r *Reconciler) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-r.wake:
			r.pass(ctx)
		}
	}
}

// outcome counts what one pass did.
type outcome struct {
	checked    int    // files whose object the bucket answered for
	removed    int    // files taken out of the history
	unverified int    // files left alone because their listing failed
	reason     string // readable cause of the first failed listing
}

func (r *Reconciler) pass(ctx context.Context) {
	r.mu.Lock()
	s, ok := r.settings, r.hasConf
	r.mu.Unlock()
	if !ok {
		return
	}
	files, err := r.history.FinishedFiles(s.Bucket)
	if err != nil {
		r.log.Warn("history reconciliation failed", "reason", "could not read the history")
		return
	}

	var out outcome
	groups := groupByPrefix(files)
	prefixes := make([]string, 0, len(groups))
	for p := range groups {
		prefixes = append(prefixes, p)
	}
	sort.Strings(prefixes)

	for i, prefix := range prefixes {
		stop := r.verify(ctx, s, prefix, groups[prefix], &out)
		if stop {
			for _, rest := range prefixes[i+1:] {
				out.unverified += len(groups[rest])
			}
			break
		}
	}
	fields := []any{"bucket", s.Bucket, "checked", out.checked, "removed", out.removed, "unverified", out.unverified}
	if out.reason != "" {
		fields = append(fields, "reason", out.reason)
	}
	r.log.Info("history reconciled", fields...)
}

// verify lists prefix and removes the files of group whose key is not in the
// listing. It reports whether the pass should stop: the daemon is shutting
// down, or the failure will hit every other listing too.
func (r *Reconciler) verify(ctx context.Context, s uploader.Settings, prefix string, group []queue.FinishedFile, out *outcome) (stop bool) {
	wanted, err := r.present(ctx, s, prefix, group)
	if err != nil {
		// Whatever the listing did return is not trusted: it may be a part.
		out.unverified += len(group)
		if out.reason == "" {
			out.reason = reasonOf(err)
		}
		return ctx.Err() != nil || uploader.IsFatal(err)
	}
	if ctx.Err() != nil {
		out.unverified += len(group)
		return true
	}

	var missing []queue.FinishedFile
	for _, f := range group {
		if !wanted[f.ObjectKey] {
			missing = append(missing, f)
		}
	}
	out.checked += len(group)
	if len(missing) == 0 {
		return false
	}
	removed, err := r.history.ForgetMissing(s.Bucket, missing)
	out.removed += removed
	if err != nil {
		out.reason = "could not update the history"
	}
	return false
}

// present lists prefix and returns, for the key of each file of group, whether
// the listing contained it. Only a listing that ran to the end is an answer.
func (r *Reconciler) present(ctx context.Context, s uploader.Settings, prefix string, group []queue.FinishedFile) (map[string]bool, error) {
	found := make(map[string]bool, len(group))
	for _, f := range group {
		found[f.ObjectKey] = false
	}
	err := r.lister.ListKeys(ctx, s, prefix, func(key string) {
		if _, ok := found[key]; ok {
			found[key] = true
		}
	})
	return found, err
}

// reasonOf describes a failed listing without the text of the error, which may
// echo request content.
func reasonOf(err error) string {
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "cancelled"
	case uploader.IsFatal(err):
		return uploader.Message(err)
	}
	return "listing failed"
}

// groupByPrefix groups files by the key prefix one listing covers: the
// destination of the folder a file was found in, or the folder of its key for a
// file sent on its own.
func groupByPrefix(files []queue.FinishedFile) map[string][]queue.FinishedFile {
	groups := map[string][]queue.FinishedFile{}
	for _, f := range files {
		p := listingPrefix(f)
		groups[p] = append(groups[p], f)
	}
	return groups
}

func listingPrefix(f queue.FinishedFile) string {
	if f.Inner != "" && strings.HasSuffix(f.ObjectKey, "/"+f.Inner) {
		return strings.TrimSuffix(f.ObjectKey, f.Inner)
	}
	if i := strings.LastIndex(f.ObjectKey, "/"); i >= 0 {
		return f.ObjectKey[:i+1]
	}
	return ""
}
