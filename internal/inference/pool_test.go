package inference

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestPoolCancelBeforeAcquire(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 1, 0, 0)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = pool.Predict(ctx, "minimal", []float64{1, 2, 3, 4, 0, 12, 5, 0.1, 0.2})
	require.ErrorIs(t, err, context.Canceled)
}

func TestPoolPredict(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 2, 0, 0)
	v, err := pool.Predict(context.Background(), "minimal", []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2})
	require.NoError(t, err)
	require.NotZero(t, v)
}

func TestPoolUnlimitedConcurrency(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 0, 0, 0)
	require.Nil(t, pool.sem)
	v, err := pool.Predict(context.Background(), "minimal", []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2})
	require.NoError(t, err)
	require.NotZero(t, v)
}

func TestPoolAdmissionBusyWhenFullNoWaiters(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 0, 1, 0)
	features := []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2}

	started := make(chan struct{})
	release := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		require.NoError(t, pool.acquire(context.Background()))
		close(started)
		<-release
		pool.release()
	}()
	<-started

	_, err = pool.Predict(context.Background(), "minimal", features)
	require.ErrorIs(t, err, BusyError{})

	close(release)
	wg.Wait()
}

func TestPoolAdmissionWaitsThenRuns(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 0, 1, 2)
	features := []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2}

	require.NoError(t, pool.acquire(context.Background()))
	done := make(chan error, 1)
	go func() {
		_, err := pool.Predict(context.Background(), "minimal", features)
		done <- err
	}()

	time.Sleep(50 * time.Millisecond)
	pool.release()
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for queued predict")
	}
}

func TestPoolAdmissionBusyWhenWaitersFull(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 0, 1, 1)
	features := []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2}

	require.NoError(t, pool.acquire(context.Background()))
	go func() {
		_, _ = pool.Predict(context.Background(), "minimal", features)
	}()
	require.Eventually(t, func() bool { return pool.waiters.Load() >= 1 }, time.Second, 5*time.Millisecond)

	_, err = pool.Predict(context.Background(), "minimal", features)
	require.ErrorIs(t, err, BusyError{})
	pool.release()
}

func TestPoolRunHoldsSlotAcrossNestedPredicts(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 0, 1, 0)
	features := []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2}

	err = pool.Run(context.Background(), func(ctx context.Context) error {
		if _, err := pool.Predict(ctx, "minimal", features); err != nil {
			return err
		}
		_, err := pool.Predict(ctx, "minimal", features)
		return err
	})
	require.NoError(t, err)
}
