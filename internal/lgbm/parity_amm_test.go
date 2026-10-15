package lgbm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestAMMGoLGBMParityWithPython(t *testing.T) {
	modelPath := os.Getenv("AMM_MODEL_TXT")
	if modelPath == "" {
		modelPath = filepath.Join("..", "..", "testdata", "parity", "AMM.txt")
	}
	samplesPath := filepath.Join("..", "..", "testdata", "amm_samples.jsonl")

	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("AMM model not found at %s (export from Downloads/AMM.pkl)", modelPath)
	}
	if _, err := os.Stat(samplesPath); err != nil {
		t.Skipf("run tools/parity_amm.py to create %s", samplesPath)
	}

	b, err := LoadFromFile(modelPath)
	require.NoError(t, err)
	data, err := os.ReadFile(samplesPath)
	require.NoError(t, err)

	const tol = 1e-6
	var maxDiff float64
	count := 0
	for _, line := range splitLines(data) {
		var rec struct {
			Features  []float64 `json:"features"`
			PythonETA float64   `json:"python_eta"`
		}
		require.NoError(t, json.Unmarshal(line, &rec))
		got, err := b.PredictRow(rec.Features)
		require.NoError(t, err)
		diff := abs(got - rec.PythonETA)
		if diff > maxDiff {
			maxDiff = diff
		}
		if diff > tol {
			t.Fatalf("row %d: go=%v python=%v diff=%v", count, got, rec.PythonETA, diff)
		}
		count++
	}
	t.Logf("AMM parity: %d rows, max diff %g", count, maxDiff)
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

func splitLines(b []byte) [][]byte {
	var out [][]byte
	start := 0
	for i, c := range b {
		if c == '\n' {
			if i > start {
				out = append(out, b[start:i])
			}
			start = i + 1
		}
	}
	return out
}
