package ratelimit

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"
)

// fakeClock moves only when a sleeper waits.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Sleep(_ context.Context, d time.Duration, _ <-chan struct{}) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
	return nil
}

func newFakeLimiter() (*Limiter, *fakeClock) {
	c := &fakeClock{now: time.Unix(1000, 0)}
	return New(c.Now, c.Sleep), c
}

func TestReaderSendsAtTheConfiguredRate(t *testing.T) {
	l, clock := newFakeLimiter()
	l.SetRate(10_000)
	start := clock.Now()

	got, err := io.Copy(io.Discard, l.Reader(context.Background(), bytes.NewReader(make([]byte, 50_000))))
	if err != nil || got != 50_000 {
		t.Fatalf("copied %d bytes, err %v; want 50000", got, err)
	}
	elapsed := clock.Now().Sub(start)
	// 50 000 bytes at 10 000 B/s take 5 s, less the one burst the bucket allows.
	if elapsed < 3900*time.Millisecond || elapsed > 5100*time.Millisecond {
		t.Fatalf("elapsed = %v, want about 5s", elapsed)
	}
}

func TestReaderReturnsAtMostOneBurstPerRead(t *testing.T) {
	l, _ := newFakeLimiter()
	l.SetRate(1000)
	n, err := l.Reader(context.Background(), bytes.NewReader(make([]byte, 10_000))).Read(make([]byte, 10_000))
	if err != nil || n != 1000 {
		t.Fatalf("read %d bytes, err %v; want 1000 (one second of rate)", n, err)
	}
}

func TestUnlimitedReaderNeverWaits(t *testing.T) {
	l, clock := newFakeLimiter()
	start := clock.Now()
	if _, err := io.Copy(io.Discard, l.Reader(context.Background(), bytes.NewReader(make([]byte, 1<<20)))); err != nil {
		t.Fatal(err)
	}
	if !clock.Now().Equal(start) {
		t.Fatalf("clock moved by %v, want no wait without a limit", clock.Now().Sub(start))
	}
}

func TestChangingTheRateAppliesToTheNextBytes(t *testing.T) {
	l, clock := newFakeLimiter()
	l.SetRate(1000)
	r := l.Reader(context.Background(), bytes.NewReader(make([]byte, 100_000)))
	start := clock.Now()
	if _, err := io.CopyN(io.Discard, r, 3000); err != nil {
		t.Fatal(err)
	}
	slow := clock.Now().Sub(start)

	l.SetRate(100_000)
	start = clock.Now()
	if _, err := io.CopyN(io.Discard, r, 30_000); err != nil {
		t.Fatal(err)
	}
	fast := clock.Now().Sub(start)
	if slow < 1500*time.Millisecond {
		t.Fatalf("3000 B at 1000 B/s took %v, want at least 1.5s", slow)
	}
	if fast > 400*time.Millisecond {
		t.Fatalf("30000 B at 100000 B/s took %v, want about 0.3s after raising the limit", fast)
	}
	if l.Rate() != 100_000 {
		t.Fatalf("Rate = %d", l.Rate())
	}
}

func TestReaderWaitingForTokensIsReleasedByCancellation(t *testing.T) {
	l := New(nil, nil)
	l.SetRate(1) // one byte per second: every read waits about a second
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := io.Copy(io.Discard, l.Reader(ctx, bytes.NewReader(make([]byte, 100))))
		done <- err
	}()
	time.Sleep(50 * time.Millisecond)
	start := time.Now()
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("err = %v, want context.Canceled", err)
		}
		if d := time.Since(start); d > 300*time.Millisecond {
			t.Fatalf("released after %v, want promptly", d)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("reader still waiting after cancellation")
	}
}

func TestRaisingTheLimitReleasesAWaitingReader(t *testing.T) {
	l := New(nil, nil)
	l.SetRate(1)
	done := make(chan error, 1)
	go func() {
		_, err := io.Copy(io.Discard, l.Reader(context.Background(), bytes.NewReader(make([]byte, 100))))
		done <- err
	}()
	time.Sleep(50 * time.Millisecond)
	l.SetRate(0)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("reader kept waiting after the limit was removed")
	}
}
