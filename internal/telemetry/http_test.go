package telemetry

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestHTTPInstrumentationEnabled(t *testing.T) {
	t.Setenv("OTEL_SDK_DISABLED", "")
	t.Setenv("OTEL_GO_HTTP_OTELHTTP", "")
	t.Setenv("OTEL_TRACES_EXPORTER", "otlp")
	t.Setenv("OTEL_METRICS_EXPORTER", "none")
	require.True(t, httpInstrumentationEnabled())

	t.Setenv("OTEL_TRACES_EXPORTER", "none")
	t.Setenv("OTEL_METRICS_EXPORTER", "otlp")
	require.True(t, httpInstrumentationEnabled())

	t.Setenv("OTEL_METRICS_EXPORTER", "none")
	require.False(t, httpInstrumentationEnabled())

	t.Setenv("OTEL_GO_HTTP_OTELHTTP", "false")
	t.Setenv("OTEL_METRICS_EXPORTER", "otlp")
	require.False(t, httpInstrumentationEnabled())
}

func TestInstrumentHandlerPassthroughWhenDisabled(t *testing.T) {
	t.Setenv("OTEL_SDK_DISABLED", "true")
	called := false
	h := InstrumentHandler("test", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusNoContent)
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	require.True(t, called)
	require.Equal(t, http.StatusNoContent, rec.Code)
}
