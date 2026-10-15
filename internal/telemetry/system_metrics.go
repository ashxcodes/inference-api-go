package telemetry

import (
	"log"
	"os"
	"strings"

	othost "go.opentelemetry.io/contrib/instrumentation/host"
	"go.opentelemetry.io/otel"
)

// StartSystemMetrics registers host/process/system metrics (process.cpu.time, system.memory.*, …)
// on the global meter provider. Call after Start() so OTLP export is configured.
//
// Enabled when OTLP metrics export is on. Disable with OTEL_GO_SYSTEM_METRICS=false.
func StartSystemMetrics() {
	if !systemMetricsEnabled() {
		return
	}
	if err := othost.Start(othost.WithMeterProvider(otel.GetMeterProvider())); err != nil {
		log.Printf("telemetry: host/system metrics disabled: %v", err)
		return
	}
	log.Print("telemetry: host/system metrics enabled (process.cpu.time, system_*)")
}

func systemMetricsEnabled() bool {
	if strings.EqualFold(strings.TrimSpace(os.Getenv("OTEL_SDK_DISABLED")), "true") {
		return false
	}
	if v := strings.TrimSpace(os.Getenv("OTEL_GO_SYSTEM_METRICS")); v != "" {
		switch strings.ToLower(v) {
		case "0", "false", "no":
			return false
		default:
			return true
		}
	}
	exporter := strings.ToLower(strings.TrimSpace(os.Getenv("OTEL_METRICS_EXPORTER")))
	return exporter != "" && exporter != "none"
}
