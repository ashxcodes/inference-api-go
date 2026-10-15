package features

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestGoldenFeatures(t *testing.T) {
	root := filepath.Join("..", "..", "testdata", "golden.jsonl")
	b, err := os.ReadFile(root)
	require.NoError(t, err)
	tr := Transform{}
	for _, line := range splitLines(b) {
		var rec struct {
			Name     string                   `json:"name"`
			Request  map[string]interface{}   `json:"request"`
			Features [][]float64              `json:"features"`
		}
		require.NoError(t, json.Unmarshal(line, &rec))
		if rec.Name == "empty_created_at" {
			continue
		}
		created := rec.Request["created_at"].(string)
		ts, err := ParseCreatedAt(created)
		require.NoError(t, err, rec.Name)
		legs := legCoords(rec.Request)
		for i, leg := range legs {
			got := tr.Build(leg[0], leg[1], leg[2], leg[3], ts)
			for j := range got {
				require.InDelta(t, rec.Features[i][j], got[j], 1e-9, "%s leg %d feat %d", rec.Name, i, j)
			}
		}
	}
}

func legCoords(req map[string]interface{}) [][]float64 {
	toF := func(k string) float64 {
		v := req[k]
		switch x := v.(type) {
		case float64:
			return x
		case string:
			f, _ := strconvParse(x)
			return f
		default:
			return 0
		}
	}
	if wpTruthy(req) {
		return [][]float64{
			{toF("origin_lat"), toF("origin_lng"), toF("waypoint_lat"), toF("waypoint_lng")},
			{toF("waypoint_lat"), toF("waypoint_lng"), toF("destination_lat"), toF("destination_lng")},
		}
	}
	return [][]float64{{toF("origin_lat"), toF("origin_lng"), toF("destination_lat"), toF("destination_lng")}}
}

func wpTruthy(req map[string]interface{}) bool {
	lat, lng := req["waypoint_lat"], req["waypoint_lng"]
	if lat == nil || lng == nil {
		return false
	}
	lf := num(lat)
	lg := num(lng)
	return lf != 0 && lg != 0
}

func num(v interface{}) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case string:
		f, _ := strconvParse(x)
		return f
	default:
		return 0
	}
}

func strconvParse(s string) (float64, error) {
	return json.Number(s).Float64()
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

