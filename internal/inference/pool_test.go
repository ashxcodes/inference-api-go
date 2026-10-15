package inference

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestPoolCancelBeforeAcquire(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 1)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = pool.Predict(ctx, "minimal", []float64{1, 2, 3, 4, 0, 12, 5, 0.1, 0.2})
	require.ErrorIs(t, err, context.Canceled)
}

func TestPoolPredict(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 2)
	v, err := pool.Predict(context.Background(), "minimal", []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2})
	require.NoError(t, err)
	require.NotZero(t, v)
}

func TestPoolUnlimitedConcurrency(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := LoadModels(dir)
	require.NoError(t, err)
	pool := NewPool(dir, models, 0)
	require.Nil(t, pool.sem)
	v, err := pool.Predict(context.Background(), "minimal", []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2})
	require.NoError(t, err)
	require.NotZero(t, v)
}
