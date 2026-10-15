package httpapi

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/ashxcodes/inference-api-go/internal/eta"
)

const cacheTTL = 300 * time.Second

var healthCheckArgs = map[string]healthArgsTuple{
	"RUH":          {24.0, 46.0, 24.1, 46.1, "2024-01-01 00:00:00"},
	"JED":          {30.0, 54.0, 32.1, 56.1, "2024-01-01 00:00:00"},
	"AMM":          {28.0, 52.0, 30.1, 54.1, "2024-01-01 00:00:00"},
	"OtherCities":  {26.0, 50.0, 28.1, 52.1, "2024-01-01 00:00:00"},
	"DMM":          {26.0, 50.0, 28.1, 52.1, "2024-01-01 00:00:00"},
	"MEC":          {32.0, 56.0, 34.1, 58.1, "2024-01-01 00:00:00"},
	"MAD":          {34.0, 58.0, 36.1, 60.1, "2024-01-01 00:00:00"},
}

type healthArgsTuple struct {
	lat1, lng1, lat2, lng2 float64
	created                string
}

type healthCache struct {
	mu    sync.Mutex
	data  map[string]cachedHealth
	stamp map[string]time.Time
	eta   eta.Service
}

type cachedHealth struct {
	ok     bool
	reason string
}

func newHealthCache(s eta.Service) *healthCache {
	return &healthCache{
		data:  make(map[string]cachedHealth),
		stamp: make(map[string]time.Time),
		eta:   s,
	}
}

func (h *healthCache) check(area string) ([]byte, int) {
	args, ok := healthCheckArgs[area]
	if !ok {
		return mustJSON(map[string]string{
			"status": "fail",
			"reason": "Unknown area code: " + area,
		}), 200
	}

	now := time.Now()
	h.mu.Lock()
	if ent, ts := h.data[area], h.stamp[area]; now.Sub(ts) <= cacheTTL && ts != (time.Time{}) {
		h.mu.Unlock()
		return renderHealth(area, ent), 200
	}
	h.mu.Unlock()

	ent := h.runPredict(area, args)
	h.mu.Lock()
	h.data[area] = ent
	h.stamp[area] = now
	h.mu.Unlock()
	return renderHealth(area, ent), 200
}

func (h *healthCache) runPredict(area string, args healthArgsTuple) cachedHealth {
	_, err := h.eta.Predict(context.Background(), eta.Request{
		City:           area,
		Key:            "health",
		OriginLat:      args.lat1,
		OriginLng:      args.lng1,
		DestinationLat: args.lat2,
		DestinationLng: args.lng2,
		CreatedAt:      args.created,
	})
	if err != nil {
		return cachedHealth{ok: false, reason: area + " prediction failed: " + err.Error()}
	}
	return cachedHealth{ok: true}
}

func renderHealth(area string, ent cachedHealth) []byte {
	if ent.ok {
		return mustJSON(map[string]string{
			"status":  "ok",
			"message": "Welcome to " + area + " Machine Learning Model Service!",
		})
	}
	return mustJSON(map[string]string{"status": "fail", "reason": ent.reason})
}

func mustJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}
