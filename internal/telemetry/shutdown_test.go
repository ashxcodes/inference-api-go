package telemetry

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestFlushTimeout(t *testing.T) {
	require.Equal(t, 5*time.Second, FlushTimeout())
}

func TestShutdownNoProviders(t *testing.T) {
	require.NoError(t, Shutdown(context.Background()))
}
