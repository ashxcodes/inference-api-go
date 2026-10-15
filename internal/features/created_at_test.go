package features

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestParseCreatedAtLocationEngineFormat(t *testing.T) {
	ts, err := ParseCreatedAt("2026-01-01 00:00:00.000000")
	require.NoError(t, err)
	require.Equal(t, 3, PandasDayOfWeek(ts)) // Thursday
	require.Equal(t, 0, ts.Hour())
}

func TestParseCreatedAtUTC(t *testing.T) {
	ts, err := ParseCreatedAt("2024-12-17 08:53:45.450213 UTC")
	require.NoError(t, err)
	require.Equal(t, 8, ts.Hour())
	require.Equal(t, 1, PandasDayOfWeek(ts))
}

func TestParseCreatedAtRejectsPandasExtras(t *testing.T) {
	_, err := ParseCreatedAt("2024-03-10T22:15:00+03:00")
	require.Error(t, err)
}
