package queue

import "sync"

// subscriber keeps the latest pending value per key and delivers them, in
// order of first pending change, as fast as its reader takes them. It never
// blocks the code that pushes to it.
type subscriber[K comparable, V any] struct {
	out  chan V
	key  func(V) K
	wake chan struct{} // capacity 1
	done chan struct{}
	once sync.Once

	mu      sync.Mutex
	pending map[K]V
	order   []K
}

func newSubscriber[K comparable, V any](key func(V) K) *subscriber[K, V] {
	return &subscriber[K, V]{
		out:     make(chan V),
		key:     key,
		wake:    make(chan struct{}, 1),
		done:    make(chan struct{}),
		pending: make(map[K]V),
	}
}

func (s *subscriber[K, V]) push(v V) {
	k := s.key(v)
	s.mu.Lock()
	if _, queued := s.pending[k]; !queued {
		s.order = append(s.order, k)
	}
	s.pending[k] = v
	s.mu.Unlock()

	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *subscriber[K, V]) pop() (V, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.order) == 0 {
		var zero V
		return zero, false
	}
	k := s.order[0]
	s.order = s.order[1:]
	v := s.pending[k]
	delete(s.pending, k)
	return v, true
}

func (s *subscriber[K, V]) pump() {
	defer close(s.out)
	for {
		v, ok := s.pop()
		if !ok {
			select {
			case <-s.wake:
			case <-s.done:
				return
			}
			continue
		}
		select {
		case s.out <- v:
		case <-s.done:
			return
		}
	}
}

func (s *subscriber[K, V]) stop() { s.once.Do(func() { close(s.done) }) }
