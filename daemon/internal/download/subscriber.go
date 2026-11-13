package download

import "sync"

// subscriber keeps the latest pending snapshot per download and delivers them,
// in order of first pending change, as fast as its reader takes them. It never
// blocks the code that pushes to it, and the last snapshot of every download
// is always delivered.
type subscriber struct {
	out  chan Snapshot
	wake chan struct{} // capacity 1
	done chan struct{}
	once sync.Once

	mu      sync.Mutex
	pending map[string]Snapshot
	order   []string
}

func newSubscriber() *subscriber {
	return &subscriber{
		out:     make(chan Snapshot),
		wake:    make(chan struct{}, 1),
		done:    make(chan struct{}),
		pending: make(map[string]Snapshot),
	}
}

func (s *subscriber) push(v Snapshot) {
	s.mu.Lock()
	if _, queued := s.pending[v.ID]; !queued {
		s.order = append(s.order, v.ID)
	}
	s.pending[v.ID] = v
	s.mu.Unlock()

	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *subscriber) pop() (Snapshot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.order) == 0 {
		return Snapshot{}, false
	}
	id := s.order[0]
	s.order = s.order[1:]
	v := s.pending[id]
	delete(s.pending, id)
	return v, true
}

func (s *subscriber) pump() {
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

func (s *subscriber) stop() { s.once.Do(func() { close(s.done) }) }
