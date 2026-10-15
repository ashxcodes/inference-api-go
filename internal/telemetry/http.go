package telemetry

import (
	"net/http"
	"os"
	"strings"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// InstrumentHandler wraps the HTTP handler with otelhttp (server traces + http.server.* metrics).
func InstrumentHandler(operation string, next http.Handler) http.Handler {
	if !httpInstrumentationEnabled() {
		return next
	}
	if operation == "" {
		operation = "http"
	}
	return otelhttp.NewHandler(next, operation,
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
	)
}

func httpInstrumentationEnabled() bool {
	if strings.EqualFold(strings.TrimSpace(os.Getenv("OTEL_SDK_DISABLED")), "true") {
		return false
	}
	if v := strings.TrimSpace(os.Getenv("OTEL_GO_HTTP_OTELHTTP")); v != "" {
		switch strings.ToLower(v) {
		case "0", "false", "no":
			return false
		default:
			return true
		}
	}
	traces := strings.ToLower(strings.TrimSpace(os.Getenv("OTEL_TRACES_EXPORTER")))
	metrics := strings.ToLower(strings.TrimSpace(os.Getenv("OTEL_METRICS_EXPORTER")))
	tracesOn := traces != "" && traces != "none"
	metricsOn := metrics != "" && metrics != "none"
	return tracesOn || metricsOn
}
