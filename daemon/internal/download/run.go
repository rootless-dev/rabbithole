package download

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"rabbithole/daemon/internal/awss3"
	"rabbithole/daemon/internal/uploader"
)

// Messages for a file that failed for a reason with no sentence of its own.
const (
	fileFailedMessage = "The file could not be downloaded"
	unsafeMessage     = "The file name is not safe to write to disk"
	saveFailedMessage = "The file could not be saved to the folder"
)

// fatalErrors are the errors that will hit every other file of the download
// too, so the download stops instead of failing one file at a time.
var fatalErrors = []error{
	uploader.ErrBadCredentials, uploader.ErrBucketNotFound, uploader.ErrBucketInaccessible,
	uploader.ErrWrongRegion, uploader.ErrNoNetwork, uploader.ErrReadDenied,
}

func isFatal(err error) bool {
	for _, fatal := range fatalErrors {
		if errors.Is(err, fatal) {
			return true
		}
	}
	return false
}

// run copies the files of d and settles its final state.
func (m *Manager) run(ctx context.Context, d *download, s uploader.Settings) {
	defer m.wg.Done()
	defer d.cancel()
	src, err := m.open(ctx, s)
	if err != nil {
		m.stop(d, err)
	} else {
		m.setState(d, Downloading)
		m.copyAll(ctx, d, src)
	}
	pruneFolders(d.plan.folders)
	m.finish(ctx, d)
}

// copyAll copies the files of d, parallelFiles at a time.
func (m *Manager) copyAll(ctx context.Context, d *download, src Source) {
	jobs := make(chan plannedFile)
	var wg sync.WaitGroup
	for range min(parallelFiles, len(d.plan.files)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for f := range jobs {
				m.copyOne(ctx, d, src, f)
			}
		}()
	}
dispatch:
	for _, f := range d.plan.files {
		select {
		case jobs <- f:
		case <-ctx.Done():
			break dispatch
		}
	}
	close(jobs)
	wg.Wait()
}

// copyOne copies one file and records how it ended.
func (m *Manager) copyOne(ctx context.Context, d *download, src Source, f plannedFile) {
	err := f.err
	if err == nil {
		err = fetch(ctx, src, f, func(n int64) { m.progressed(d, n) })
	}
	switch {
	case err == nil:
		m.fileDone(d)
	case ctx.Err() != nil:
		// Canceled or shut down: finish settles it.
	case isFatal(err):
		m.stop(d, err)
	default:
		m.fileFailed(d, err)
	}
}

// stop records err as the reason the whole download cannot go on.
func (m *Manager) stop(d *download, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if d.fatal == nil {
		d.fatal = err
		d.cancel()
	}
}

func (m *Manager) setState(d *download, s State) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d.snap.State = s
	m.publish(d)
}

// progressed adds n bytes to d and publishes when a snapshot is due.
func (m *Manager) progressed(d *download, n int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d.snap.BytesDone = min(d.snap.BytesDone+n, d.snap.BytesTotal)
	if m.now().Sub(d.lastPublish) >= minProgressInterval {
		m.publish(d)
	}
}

func (m *Manager) fileDone(d *download) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d.snap.FilesDone++
	m.publish(d)
}

// fileFailed counts a file that failed on its own and logs why: the readable
// reason and the AWS code, never the error's own text.
func (m *Manager) fileFailed(d *download, err error) {
	msg := fileMessage(err)
	kv := []any{"download_id", d.snap.ID, "reason", msg}
	if code, status := awss3.ErrorDetails(err); code != "" || status != 0 {
		kv = append(kv, "aws_code", code, "http_status", status)
	}
	m.log.Warn("download file failed", kv...)

	m.mu.Lock()
	defer m.mu.Unlock()
	d.snap.FilesFailed++
	d.fileMessage = msg
	m.publish(d)
}

// fileMessage is the sentence for one file that failed.
func fileMessage(err error) string {
	switch {
	case errors.Is(err, errUnsafePath):
		return unsafeMessage
	case errors.Is(err, errSave):
		return saveFailedMessage
	case uploader.HasMessage(err):
		return uploader.Message(err)
	}
	return fileFailedMessage
}

// finish gives d its final state and publishes it.
func (m *Manager) finish(ctx context.Context, d *download) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := &d.snap
	switch {
	case d.fatal != nil:
		s.State, s.ErrorMessage = Failed, fileMessage(d.fatal)
		m.log.Warn("download stopped", "download_id", s.ID, "reason", s.ErrorMessage)
	case (d.userCanceled || ctx.Err() != nil) && s.FilesDone+s.FilesFailed < s.FilesTotal:
		s.State = Canceled
	case s.FilesFailed == 0:
		s.State, s.BytesDone = Finished, s.BytesTotal
	case s.FilesTotal == 1:
		s.State, s.ErrorMessage = Failed, d.fileMessage
	default:
		s.State = Failed
		s.ErrorMessage = fmt.Sprintf("%d of %d files could not be downloaded", s.FilesFailed, s.FilesTotal)
	}
	m.publish(d)
}

// pruneFolders removes the folders a download created that stayed empty, deepest
// first. A folder with anything in it is left alone.
func pruneFolders(roots []string) {
	for _, root := range roots {
		var dirs []string
		_ = filepath.WalkDir(root, func(p string, e os.DirEntry, err error) error {
			if err == nil && e.IsDir() {
				dirs = append(dirs, p)
			}
			return nil
		})
		sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
		for _, dir := range dirs {
			_ = os.Remove(dir) // fails, harmlessly, while the folder holds something
		}
	}
}
