package features

import (
	"math"
	"time"
)

const avgEarthRadiusKm = 6371.0

// Transform builds the 9-feature model input (transform.py).
type Transform struct{}

func (Transform) HaversineKm(lat1, lng1, lat2, lng2 float64) float64 {
	lat1r, lng1r, lat2r, lng2r := deg2rad(lat1), deg2rad(lng1), deg2rad(lat2), deg2rad(lng2)
	latDiff := lat2r - lat1r
	lngDiff := lng2r - lng1r
	a := math.Sin(latDiff*0.5)*math.Sin(latDiff*0.5) +
		math.Cos(lat1r)*math.Cos(lat2r)*math.Sin(lngDiff*0.5)*math.Sin(lngDiff*0.5)
	return 2 * avgEarthRadiusKm * math.Asin(math.Sqrt(a))
}

func (Transform) BearingDeg(lat1, lng1, lat2, lng2 float64) float64 {
	lat1r, lng1r, lat2r, lng2r := deg2rad(lat1), deg2rad(lng1), deg2rad(lat2), deg2rad(lng2)
	y := math.Sin(lng2r-lng1r) * math.Cos(lat2r)
	x := math.Cos(lat1r)*math.Sin(lat2r) - math.Sin(lat1r)*math.Cos(lat2r)*math.Cos(lng2r-lng1r)
	return rad2deg(math.Atan2(y, x))
}

func (t Transform) Build(lat1, lng1, lat2, lng2 float64, createdAt time.Time) []float64 {
	// Python pandas dayofweek: Monday=0 .. Sunday=6
	dow := float64((int(createdAt.Weekday()) + 6) % 7)
	hour := float64(createdAt.Hour())
	aerial := t.HaversineKm(lat1, lng1, lat2, lng2)
	direction := t.BearingDeg(lat1, lng1, lat2, lng2)
	sinDir := math.Sin(2 * math.Pi * (direction + 180) / 360)
	cosDir := math.Cos(2 * math.Pi * (direction + 180) / 360)
	return []float64{lat1, lng1, lat2, lng2, dow, hour, aerial, sinDir, cosDir}
}

func deg2rad(x float64) float64 {
	return x * (math.Pi / 180)
}

func rad2deg(x float64) float64 {
	return x * (180 / math.Pi)
}

