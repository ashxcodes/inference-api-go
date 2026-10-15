package lgbm

import (
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMinimalModelPredict(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "minimal.txt")
	b, err := LoadFromFile(path)
	require.NoError(t, err)
	row := []float64{24.71, 46.67, 24.75, 46.70, 1, 8, 4.5, 0.1, -0.2}
	v, err := b.PredictRow(row)
	require.NoError(t, err)
	require.False(t, v == 0 && err == nil)
}

func TestConcurrentPredict(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "minimal.txt")
	b, err := LoadFromFile(path)
	require.NoError(t, err)
	row := []float64{1, 2, 3, 4, 0, 12, 5.0, 0.1, 0.2}

	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := b.PredictRow(row)
			require.NoError(t, err)
		}()
	}
	wg.Wait()
}
