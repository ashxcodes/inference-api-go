package eta

import (
	"context"
	"fmt"
	"time"

	"github.com/jeenyme/ml-model-go/internal/features"
	"github.com/jeenyme/ml-model-go/internal/inference"
)

// Clock provides "now" for empty created_at (Asia/Riyadh).
type Clock interface {
	NowRiyadh() time.Time
}

type SystemClock struct{}

func (SystemClock) NowRiyadh() time.Time {
	loc, err := time.LoadLocation("Asia/Riyadh")
	if err != nil {
		return time.Now().UTC()
	}
	return time.Now().In(loc)
}

type Request struct {
	City            string
	Key             string
	OriginLat       float64
	OriginLng       float64
	WaypointLat     *float64
	WaypointLng     *float64
	DestinationLat  float64
	DestinationLng  float64
	CreatedAt       string
}

type Response struct {
	Key      string
	ETA      float64
	Distance float64
}

type Service struct {
	Transform  features.Transform
	Predictor  inference.Predictor
	Clock      Clock
}

func (s Service) Predict(ctx context.Context, req Request) (Response, error) {
	created := req.CreatedAt
	if created == "" {
		created = s.Clock.NowRiyadh().Format("2006-01-02 15:04:05")
	}
	createdAt, err := features.ParseCreatedAt(created)
	if err != nil {
		return Response{}, err
	}

	wpLat, wpLng, hasWaypoint := waypointTruthy(req.WaypointLat, req.WaypointLng)

	var eta float64
	var distance float64

	if hasWaypoint {
		f1 := s.Transform.Build(req.OriginLat, req.OriginLng, wpLat, wpLng, createdAt)
		p1, err := s.Predictor.Predict(ctx, req.City, f1)
		if err != nil {
			return Response{}, MapPredictError(err)
		}
		f2 := s.Transform.Build(wpLat, wpLng, req.DestinationLat, req.DestinationLng, createdAt)
		p2, err := s.Predictor.Predict(ctx, req.City, f2)
		if err != nil {
			return Response{}, MapPredictError(err)
		}
		eta = p1 + p2
		d1 := features.Round2(s.Transform.HaversineKm(req.OriginLat, req.OriginLng, wpLat, wpLng))
		d2 := features.Round2(s.Transform.HaversineKm(wpLat, wpLng, req.DestinationLat, req.DestinationLng))
		distance = d1 + d2
	} else {
		f := s.Transform.Build(req.OriginLat, req.OriginLng, req.DestinationLat, req.DestinationLng, createdAt)
		p, err := s.Predictor.Predict(ctx, req.City, f)
		if err != nil {
			return Response{}, MapPredictError(err)
		}
		eta = p
		distance = features.Round2(s.Transform.HaversineKm(
			req.OriginLat, req.OriginLng, req.DestinationLat, req.DestinationLng,
		))
	}

	return Response{Key: req.Key, ETA: eta, Distance: distance}, nil
}

func waypointTruthy(lat, lng *float64) (float64, float64, bool) {
	if lat == nil || lng == nil {
		return 0, 0, false
	}
	if *lat == 0 || *lng == 0 {
		return 0, 0, false
	}
	return *lat, *lng, true
}

// ModelError is returned for missing model / bad predict (HTTP 400).
type ModelError struct {
	Msg string
}

func (e ModelError) Error() string { return e.Msg }

func MapPredictError(err error) error {
	if err == nil {
		return nil
	}
	if _, ok := err.(inference.NotFoundError); ok {
		return ModelError{Msg: err.Error()}
	}
	if _, ok := err.(inference.PredictError); ok {
		return ModelError{Msg: err.Error()}
	}
	return fmt.Errorf("%w", err)
}
