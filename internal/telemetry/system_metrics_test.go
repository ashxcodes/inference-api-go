package telemetry

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSystemMetricsEnabled(t *testing.T) {
	t.Setenv("OTEL_SDK_DISABLED", "")
	t.Setenv("OTEL_GO_SYSTEM_METRICS", "")
	t.Setenv("OTEL_METRICS_EXPORTER", "otlp")
	require.True(t, systemMetricsEnabled())

	t.Setenv("OTEL_SDK_DISABLED", "true")
	require.False(t, systemMetricsEnabled())

	t.Setenv("OTEL_SDK_DISABLED", "false")
	t.Setenv("OTEL_METRICS_EXPORTER", "none")
	require.False(t, systemMetricsEnabled())

	t.Setenv("OTEL_METRICS_EXPORTER", "otlp")
	t.Setenv("OTEL_GO_SYSTEM_METRICS", "false")
	require.False(t, systemMetricsEnabled())

	t.Setenv("OTEL_GO_SYSTEM_METRICS", "1")
	require.True(t, systemMetricsEnabled())
}
