package httpapi

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/ashxcodes/inference-api-go/internal/config"
	"github.com/ashxcodes/inference-api-go/internal/eta"
	"github.com/ashxcodes/inference-api-go/internal/logging"
)

type Server struct {
	cfg        config.Config
	eta        eta.Service
	health     *healthCache
	log        *logging.AccessLogger
	ready      func() bool
	apiKey     string
}

func NewServer(cfg config.Config, etaSvc eta.Service, log *logging.AccessLogger, ready func() bool) *Server {
	return &Server{
		cfg:    cfg,
		eta:    etaSvc,
		health: newHealthCache(etaSvc),
		log:    log,
		ready:  ready,
		apiKey: cfg.ModelAPIKey,
	}
}

func (s *Server) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/":
			s.handleRoot(w, r)
		case r.Method == http.MethodGet && r.URL.Path == "/healthz":
			s.handleHealthz(w, r)
		case r.Method == http.MethodGet && r.URL.Path == "/readyz":
			s.handleReadyz(w, r)
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/health-check-"):
			s.handleHealthCheck(w, r)
		case r.Method == http.MethodPost && r.URL.Path == "/predict":
			s.handlePredict(w, r)
		default:
			http.NotFound(w, r)
		}
	})
}

func (s *Server) handleRoot(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func (s *Server) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	if s.ready != nil && !s.ready() {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *Server) handleHealthCheck(w http.ResponseWriter, r *http.Request) {
	area := strings.TrimPrefix(r.URL.Path, "/health-check-")
	body, code := s.health.check(area)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

func (s *Server) handlePredict(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	var reqBody []byte
	var respBody []byte
	status := http.StatusOK

	defer func() {
		if s.log != nil && !strings.HasPrefix(strings.ToLower(r.URL.Path), "/health-check") {
			s.log.LogAccess(r, reqBody, status, respBody, start, "", "")
		}
	}()

	if r.Header.Get("X-API-Key") != s.apiKey {
		status = http.StatusForbidden
		respBody = []byte(`{"detail":"Invalid API key."}`)
		writeRaw(w, status, respBody)
		return
	}

	reqBody, err := io.ReadAll(r.Body)
	if err != nil {
		status = http.StatusInternalServerError
		respBody = []byte(`{"detail":"read body"}`)
		writeRaw(w, status, respBody)
		return
	}

	req, err := decodePredictRequest(reqBody)
	if err != nil {
		status = http.StatusUnprocessableEntity
		respBody = []byte(`{"detail":"validation error"}`)
		writeRaw(w, status, respBody)
		return
	}

	var wpLat, wpLng *float64
	if req.WaypointLat != nil {
		v := float64(*req.WaypointLat)
		wpLat = &v
	}
	if req.WaypointLng != nil {
		v := float64(*req.WaypointLng)
		wpLng = &v
	}

	etaReq := eta.Request{
		City:           req.City,
		Key:            req.Key,
		OriginLat:      float64(req.OriginLat),
		OriginLng:      float64(req.OriginLng),
		WaypointLat:    wpLat,
		WaypointLng:    wpLng,
		DestinationLat: float64(req.DestinationLat),
		DestinationLng: float64(req.DestinationLng),
		CreatedAt:      req.CreatedAt,
	}

	resp, err := s.eta.Predict(r.Context(), etaReq)
	if err != nil {
		if me, ok := err.(eta.ModelError); ok {
			status = http.StatusBadRequest
			b, _ := json.Marshal(map[string]string{"detail": me.Msg})
			respBody = b
			writeRaw(w, status, respBody)
			return
		}
		status = http.StatusInternalServerError
		b, _ := json.Marshal(map[string]string{"detail": err.Error()})
		respBody = b
		writeRaw(w, status, respBody)
		return
	}

	respBody, err = encodePredictResponse(resp.Key, resp.ETA, resp.Distance)
	if err != nil {
		status = http.StatusInternalServerError
		respBody = []byte(`{"detail":"encode"}`)
		writeRaw(w, status, respBody)
		return
	}
	writeRaw(w, status, respBody)
}

func writeRaw(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
