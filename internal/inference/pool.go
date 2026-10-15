package inference

import (
	"context"
	"fmt"
)

// Predictor runs model inference with bounded concurrency.
type Predictor interface {
	Predict(ctx context.Context, city string, features []float64) (float64, error)
}

// Pool limits concurrent predictions when concurrency >= 1.
// concurrency == 0 disables the semaphore (unlimited in-flight predicts on shared boosters).
type Pool struct {
	dir    string
	models map[string]*Model
	sem    chan struct{} // nil when unlimited
}

func NewPool(dir string, models map[string]*Model, concurrency int) *Pool {
	p := &Pool{dir: dir, models: models}
	if concurrency == 0 {
		return p
	}
	if concurrency < 1 {
		concurrency = 1
	}
	p.sem = make(chan struct{}, concurrency)
	return p
}

func (p *Pool) acquire(ctx context.Context) error {
	if p.sem == nil {
		return ctx.Err()
	}
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
	if err := p.acquire(ctx); err != nil {
		return 0, err
	}
	defer p.release()

	val, err := m.Booster.PredictRow(features)
	if err != nil {
		return 0, PredictError{Msg: fmt.Sprintf("Prediction failed for model '%s': %s", city, err)}
	}
	return val, nil
}
