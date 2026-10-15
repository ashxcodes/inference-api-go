package httpapi

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDecodePredictRequestRequiredFields(t *testing.T) {
	base := `{"city":"RUH","key":"k","origin_lat":1,"origin_lng":2,"destination_lat":3,"destination_lng":4,"created_at":"2024-01-01 00:00:00"}`
	_, err := decodePredictRequest([]byte(base))
	require.NoError(t, err)

	_, err = decodePredictRequest([]byte(`{"key":"k","origin_lat":1,"origin_lng":2,"destination_lat":3,"destination_lng":4,"created_at":"x"}`))
	require.Error(t, err)

	_, err = decodePredictRequest([]byte(`{"city":"RUH","key":"k","origin_lng":2,"destination_lat":3,"destination_lng":4,"created_at":"x"}`))
	require.Error(t, err)

	_, err = decodePredictRequest([]byte(`{"city":"RUH","key":"k","origin_lat":null,"origin_lng":2,"destination_lat":3,"destination_lng":4,"created_at":"x"}`))
	require.Error(t, err)

	_, err = decodePredictRequest([]byte(base + ` extra`))
	require.Error(t, err)

	_, err = decodePredictRequest([]byte(`{"City":"RUH","key":"k","origin_lat":1,"origin_lng":2,"destination_lat":3,"destination_lng":4,"created_at":"x"}`))
	require.Error(t, err)

	_, err = decodePredictRequest([]byte(`{"city":"","key":"","origin_lat":1,"origin_lng":2,"destination_lat":3,"destination_lng":4,"created_at":"x"}`))
	require.NoError(t, err)
}

func TestFlexFloatRejectsNull(t *testing.T) {
	var f FlexFloat
	require.Error(t, f.UnmarshalJSON([]byte("null")))
}
