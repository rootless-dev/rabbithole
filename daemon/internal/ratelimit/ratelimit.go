// Package ratelimit limits how many bytes per second all uploads together may
// send. One Limiter is shared by every file and part being sent in parallel.
package ratelimit

import (
	"context"
	"io"
	"sync"
	"time"
)

// maxBurstFloor is the smallest chunk a limited reader hands out, unless the
// rate itself is lower.
const maxBurstFloor = 4096

// Sleeper waits for d, or until ctx ends or interrupt is closed, whichever
// comes first. It returns ctx.Err() when the context ended, nil otherwise.
type Sleeper func(ctx context.Context, d time.Duration, interrupt <-chan struct{}) error

// Limiter is a token bucket. A rate of zero means no limit. It is safe for
// concurrent use.
type Limiter struct {
	now   func() time.Time
	sleep Sleeper

	mu     sync.Mutex
	rate   int64 // bytes per second; 0 = unlimited
	tokens float64
	last   time.Time
	change chan struct{} // closed and replaced by every SetRate
}

// New returns an unlimited Limiter that reads the time from now and waits with
// sleep. Nil values select the real clock.
func New(now func() time.Time, sleep Sleeper) *Limiter {
	if now == nil {
		now = time.Now
	}
	if sleep == nil {
		sleep = realSleep
	}
	return &Limiter{now: now, sleep: sleep, change: make(chan struct{})}
}

func realSleep(ctx context.Context, d time.Duration, interrupt <-chan struct{}) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
	case <-interrupt:
	case <-ctx.Done():
		return ctx.Err()
	}
	return nil
}

// SetRate sets the most bytes per second; zero or less removes the limit. It
// takes effect at once, also for readers that are waiting.
func (l *Limiter) SetRate(bytesPerSecond int64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.rate = max(bytesPerSecond, 0)
	l.tokens = 0
	l.last = l.now()
	close(l.change)
	l.change = make(chan struct{})
}

// Rate is the current limit in bytes per second; zero means none.
func (l *Limiter) Rate() int64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.rate
}

// burst is the most bytes one wait covers. The caller holds l.mu.
func (l *Limiter) burst() int64 {
	return max(l.rate/10, min(l.rate, maxBurstFloor))
}

// Wait blocks until n bytes may be sent. It returns ctx.Err() as soon as the
// context ends.
func (l *Limiter) Wait(ctx context.Context, n int) error {
	for {
		wait, interrupt, done := l.reserve(n)
		if done {
			return ctx.Err()
		}
		if err := l.sleep(ctx, wait, interrupt); err != nil {
			return err
		}
		if !l.changed(interrupt) {
			return nil
		}
	}
}

// reserve takes n tokens, possibly leaving the bucket in debt. It returns how
// long to wait for the debt to clear, and done when no wait is needed.
func (l *Limiter) reserve(n int) (wait time.Duration, interrupt <-chan struct{}, done bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.rate == 0 {
		return 0, nil, true
	}
	now := l.now()
	l.tokens = min(l.tokens+now.Sub(l.last).Seconds()*float64(l.rate), float64(l.burst()))
	l.last = now
	l.tokens -= float64(n)
	if l.tokens >= 0 {
		return 0, nil, true
	}
	return time.Duration(-l.tokens / float64(l.rate) * float64(time.Second)), l.change, false
}

// changed reports whether the rate changed while a wait was under way, which
// voids the reservation of that wait.
func (l *Limiter) changed(interrupt <-chan struct{}) bool {
	select {
	case <-interrupt:
		return true
	default:
		return false
	}
}

// Reader returns r limited by l: each Read returns at most one burst, and
// returns only after the limiter allowed the bytes it read. A Read that waits
// for the limiter returns promptly with the context's error when ctx ends.
func (l *Limiter) Reader(ctx context.Context, r io.Reader) io.Reader {
	return &limitedReader{l: l, ctx: ctx, r: r}
}

type limitedReader struct {
	l   *Limiter
	ctx context.Context
	r   io.Reader
}

func (lr *limitedReader) Read(p []byte) (int, error) {
	if err := lr.ctx.Err(); err != nil {
		return 0, err
	}
	lr.l.mu.Lock()
	if b := lr.l.burst(); b > 0 && int64(len(p)) > b {
		p = p[:b]
	}
	lr.l.mu.Unlock()
	n, err := lr.r.Read(p)
	if n > 0 {
		if werr := lr.l.Wait(lr.ctx, n); werr != nil {
			return 0, werr
		}
	}
	return n, err
}
