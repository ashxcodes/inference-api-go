package telemetry

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRuntimeMetricsEnabled(t *testing.T) {
	t.Setenv("OTEL_SDK_DISABLED", "")
	t.Setenv("OTEL_GO_RUNTIME_METRICS", "")
	t.Setenv("OTEL_GO_ENABLED_INSTRUMENTATIONS", "")
	t.Setenv("OTEL_GO_DISABLED_INSTRUMENTATIONS", "")
	t.Setenv("OTEL_METRICS_EXPORTER", "otlp")
	require.True(t, runtimeMetricsEnabled())

	t.Setenv("OTEL_SDK_DISABLED", "true")
	require.False(t, runtimeMetricsEnabled())

	t.Setenv("OTEL_SDK_DISABLED", "false")
	t.Setenv("OTEL_METRICS_EXPORTER", "none")
	require.False(t, runtimeMetricsEnabled())

	t.Setenv("OTEL_METRICS_EXPORTER", "otlp")
	t.Setenv("OTEL_GO_RUNTIME_METRICS", "false")
	require.False(t, runtimeMetricsEnabled())

	t.Setenv("OTEL_GO_RUNTIME_METRICS", "")
	t.Setenv("OTEL_GO_DISABLED_INSTRUMENTATIONS", "runtimemetrics")
	require.False(t, runtimeMetricsEnabled())

	t.Setenv("OTEL_GO_DISABLED_INSTRUMENTATIONS", "")
	t.Setenv("OTEL_GO_ENABLED_INSTRUMENTATIONS", "nethttp")
	require.False(t, runtimeMetricsEnabled())

	t.Setenv("OTEL_GO_ENABLED_INSTRUMENTATIONS", "runtimemetrics,nethttp")
	require.True(t, runtimeMetricsEnabled())
}

func TestStartSDKDisabled(t *testing.T) {
	t.Setenv("OTEL_SDK_DISABLED", "true")
	Start()
	require.Nil(t, tracerProvider)
	require.Nil(t, meterProvider)
}
