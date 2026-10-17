package inference

import (
	"context"
	"sync/atomic"
)

type Predictor interface {
	Predict(ctx context.Context, city string, features []float64) (float64, error)
}

// Runner runs fn under a single admission slot; nested Predict calls reuse it.
type Runner interface {
	Run(ctx context.Context, fn func(context.Context) error) error
}

// BusyError is returned when the predict admission queue is full.
type BusyError struct{}

func (BusyError) Error() string { return "predict queue full" }

type admittedKey struct{}

// Pool bounds concurrent predicts (admission via maxInFlight/maxWaiters, or legacy concurrency).
type Pool struct {
	dir        string
	models     map[string]*Model
	sem        chan struct{}
	maxWaiters int64 // -1 = unbounded wait (legacy concurrency mode)
	waiters    atomic.Int64
}

func NewPool(dir string, models map[string]*Model, concurrency, maxInFlight, maxWaiters int) *Pool {
	p := &Pool{dir: dir, models: models, maxWaiters: -1}
	if maxInFlight > 0 {
		if maxWaiters < 0 {
			maxWaiters = 0
		}
		p.sem = make(chan struct{}, maxInFlight)
		p.maxWaiters = int64(maxWaiters)
		return p
	}
	if concurrency == 0 {
		return p
	}
	if concurrency < 1 {
		concurrency = 1
	}
	p.sem = make(chan struct{}, concurrency)
	return p
}

func (p *Pool) Run(ctx context.Context, fn func(context.Context) error) error {
	if admitted(ctx) {
		return fn(ctx)
	}
	if err := p.acquire(ctx); err != nil {
		return err
	}
	defer p.release()
	return fn(context.WithValue(ctx, admittedKey{}, true))
}

func admitted(ctx context.Context) bool {
	v, _ := ctx.Value(admittedKey{}).(bool)
	return v
}

func (p *Pool) acquire(ctx context.Context) error {
	if p.sem == nil {
		return ctx.Err()
	}
	select {
	case p.sem <- struct{}{}:
		return nil
	default:
	}

	if p.maxWaiters >= 0 {
		if !p.reserveWaiter() {
			return BusyError{}
		}
		defer p.waiters.Add(-1)
	}
	return p.waitSlot(ctx)
}

func (p *Pool) reserveWaiter() bool {
	if p.maxWaiters == 0 {
		return false
	}
	if p.waiters.Add(1) > p.maxWaiters {
		p.waiters.Add(-1)
		return false
	}
	return true
}

func (p *Pool) waitSlot(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case p.sem <- struct{}{}:
		return nil
	}
}

func (p *Pool) release() {
	if p.sem != nil {
		<-p.sem
	}
}

func (p *Pool) Predict(ctx context.Context, city string, features []float64) (float64, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	m, ok := p.models[city]
	if !ok {
		return 0, NotFoundError{City: city, Dir: p.dir}
	}
	if !admitted(ctx) {
		if err := p.acquire(ctx); err != nil {
			return 0, err
		}
		defer p.release()
	}

	val, err := m.Booster.PredictRow(features)
	if err != nil {
		return 0, PredictError{City: city, Err: err}
	}
	return val, nil
}
