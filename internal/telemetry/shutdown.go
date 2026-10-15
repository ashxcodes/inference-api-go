package telemetry

import (
	"context"
	"time"
)

// FlushTimeout is used when shutting down OTLP batch exporters.
func FlushTimeout() time.Duration { return 5 * time.Second }

// Shutdown flushes SDK trace, metric, and log providers started by Start.
func Shutdown(ctx context.Context) error {
	var err error
	if tracerProvider != nil {
		if shutdownErr := tracerProvider.Shutdown(ctx); shutdownErr != nil {
			err = shutdownErr
		}
	}
	if meterProvider != nil {
		if shutdownErr := meterProvider.Shutdown(ctx); shutdownErr != nil {
			err = shutdownErr
		}
	}
	if loggerProvider != nil {
		if shutdownErr := loggerProvider.Shutdown(ctx); shutdownErr != nil {
			err = shutdownErr
		}
	}
	return err
}
