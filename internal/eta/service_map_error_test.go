package eta

import (
	"errors"
	"fmt"
	"testing"

	"github.com/ashxcodes/inference-api-go/internal/inference"
	"github.com/stretchr/testify/require"
)

func TestMapPredictErrorUsesErrorsAsThroughWrap(t *testing.T) {
	busy := fmt.Errorf("wrap: %w", inference.BusyError{})
	require.ErrorIs(t, MapPredictError(busy), inference.BusyError{})

	notFound := fmt.Errorf("wrap: %w", inference.NotFoundError{City: "X", Dir: "/m"})
	var me ModelError
	require.True(t, errors.As(MapPredictError(notFound), &me))

	predictErr := fmt.Errorf("wrap: %w", inference.PredictError{City: "X", Err: errors.New("boom")})
	require.True(t, errors.As(MapPredictError(predictErr), &me))
	require.Contains(t, me.Msg, "boom")
}
