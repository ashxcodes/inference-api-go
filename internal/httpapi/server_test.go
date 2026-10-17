package httpapi

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ashxcodes/inference-api-go/internal/config"
	"github.com/ashxcodes/inference-api-go/internal/eta"
	"github.com/ashxcodes/inference-api-go/internal/features"
	"github.com/ashxcodes/inference-api-go/internal/inference"
	"github.com/stretchr/testify/require"
)

type mockPredictor struct {
	val float64
}

func (m mockPredictor) Predict(_ context.Context, _ string, _ []float64) (float64, error) {
	return m.val, nil
}

type busyPredictor struct{}

func (busyPredictor) Predict(_ context.Context, _ string, _ []float64) (float64, error) {
	return 0, inference.BusyError{}
}

func TestPredictRequiresAPIKey(t *testing.T) {
	cfg := config.Config{ModelAPIKey: "secret", Port: 8456}
	svc := eta.Service{Predictor: mockPredictor{12.5}}
	srv := NewServer(cfg, svc, nil, func() bool { return true })
	body := `{"city":"RUH","key":"k","origin_lat":1,"origin_lng":2,"destination_lat":3,"destination_lng":4,"created_at":"2024-01-01 00:00:00"}`
	req := httptest.NewRequest(http.MethodPost, "/predict", bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	require.Equal(t, http.StatusForbidden, rec.Code)
	require.JSONEq(t, `{"detail":"Invalid API key."}`, rec.Body.String())
}

func TestPredictOK(t *testing.T) {
	cfg := config.Config{ModelAPIKey: "secret", Port: 8456}
	svc := eta.Service{
		Transform: features.Transform{},
		Predictor: mockPredictor{12.5},
		Clock:     eta.SystemClock{},
	}
	srv := NewServer(cfg, svc, nil, func() bool { return true })
	body := `{"city":"RUH","key":"trip-1","origin_lat":24.71,"origin_lng":46.67,"destination_lat":24.75,"destination_lng":46.70,"created_at":"2024-06-15 08:30:00"}`
	req := httptest.NewRequest(http.MethodPost, "/predict", bytes.NewReader([]byte(body)))
	req.Header.Set("X-API-Key", "secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)
	require.Contains(t, rec.Body.String(), `"key":"trip-1"`)
}

func TestPredictValidationMissingCoords(t *testing.T) {
	cfg := config.Config{ModelAPIKey: "secret", Port: 8456}
	svc := eta.Service{Transform: features.Transform{}, Predictor: mockPredictor{1}, Clock: eta.SystemClock{}}
	srv := NewServer(cfg, svc, nil, func() bool { return true })
	body := `{"city":"RUH","key":"k","destination_lat":3,"destination_lng":4,"created_at":"2024-01-01 00:00:00"}`
	req := httptest.NewRequest(http.MethodPost, "/predict", bytes.NewReader([]byte(body)))
	req.Header.Set("X-API-Key", "secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	require.Equal(t, http.StatusUnprocessableEntity, rec.Code)
}

func TestHealthCheckAlways200(t *testing.T) {
	cfg := config.Config{ModelAPIKey: "secret", Port: 8456}
	svc := eta.Service{Transform: features.Transform{}, Predictor: mockPredictor{1}, Clock: eta.SystemClock{}}
	srv := NewServer(cfg, svc, nil, func() bool { return true })
	req := httptest.NewRequest(http.MethodGet, "/health-check-XYZ", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)
}

func TestPredictWrongMethodReturns405(t *testing.T) {
	cfg := config.Config{ModelAPIKey: "secret", Port: 8456}
	svc := eta.Service{Predictor: mockPredictor{1}}
	srv := NewServer(cfg, svc, nil, func() bool { return true })
	req := httptest.NewRequest(http.MethodGet, "/predict", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	require.Equal(t, http.StatusMethodNotAllowed, rec.Code)
}

func TestPredictBusyReturns503WithRetryAfter(t *testing.T) {
	cfg := config.Config{ModelAPIKey: "secret", Port: 8456, PredictRetryAfter: 3}
	svc := eta.Service{
		Transform: features.Transform{},
		Predictor: busyPredictor{},
		Clock:     eta.SystemClock{},
	}
	srv := NewServer(cfg, svc, nil, func() bool { return true })
	body := `{"city":"RUH","key":"k","origin_lat":24.71,"origin_lng":46.67,"destination_lat":24.75,"destination_lng":46.70,"created_at":"2024-06-15 08:30:00"}`
	req := httptest.NewRequest(http.MethodPost, "/predict", bytes.NewReader([]byte(body)))
	req.Header.Set("X-API-Key", "secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	require.Equal(t, http.StatusServiceUnavailable, rec.Code)
	require.Equal(t, "3", rec.Header().Get("Retry-After"))
	require.JSONEq(t, `{"detail":"predict queue full"}`, rec.Body.String())
}
