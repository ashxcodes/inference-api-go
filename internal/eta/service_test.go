package eta

import (
	"context"
	"path/filepath"
	"sync"
	"testing"

	"github.com/ashxcodes/inference-api-go/internal/features"
	"github.com/ashxcodes/inference-api-go/internal/inference"
	"github.com/stretchr/testify/require"
)

func TestWaypointUsesOneAdmissionSlot(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := inference.LoadModels(dir)
	require.NoError(t, err)
	pool := inference.NewPool(dir, models, 0, 1, 0)

	svc := Service{
		Transform: features.Transform{},
		Predictor: pool,
		Clock:     SystemClock{},
	}
	wpLat, wpLng := 24.72, 46.68
	resp, err := svc.Predict(context.Background(), Request{
		City:           "minimal",
		Key:            "k",
		OriginLat:      24.71,
		OriginLng:      46.67,
		WaypointLat:    &wpLat,
		WaypointLng:    &wpLng,
		DestinationLat: 24.75,
		DestinationLng: 46.70,
		CreatedAt:      "2024-01-01 12:00:00",
	})
	require.NoError(t, err)
	require.NotZero(t, resp.ETA)
}

func TestWaypointBusyBeforeEitherLeg(t *testing.T) {
	dir := filepath.Join("..", "..", "testdata")
	models, err := inference.LoadModels(dir)
	require.NoError(t, err)
	pool := inference.NewPool(dir, models, 0, 1, 0)
	svc := Service{Transform: features.Transform{}, Predictor: pool, Clock: SystemClock{}}

	holding := make(chan struct{})
	release := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = pool.Run(context.Background(), func(context.Context) error {
			close(holding)
			<-release
			return nil
		})
	}()
	<-holding

	wpLat, wpLng := 24.72, 46.68
	_, err = svc.Predict(context.Background(), Request{
		City: "minimal", Key: "k",
		OriginLat: 24.71, OriginLng: 46.67,
		WaypointLat: &wpLat, WaypointLng: &wpLng,
		DestinationLat: 24.75, DestinationLng: 46.70,
		CreatedAt: "2024-01-01 12:00:00",
	})
	require.ErrorIs(t, err, inference.BusyError{})

	close(release)
	wg.Wait()
}
