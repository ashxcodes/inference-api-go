package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	ModelAPIKey         string
	ModelDir            string
	Port                int
	PredictConcurrency  int
	LogCaptureBodies    bool
	LogQueueSize        int
	LogFlushInterval    time.Duration
	ShutdownDrain       time.Duration
	ServiceVersion      string
}

func Load() (Config, error) {
	c := Config{
		ModelDir:           envOr("MODEL_DIR", "/models"),
		Port:               envInt("PORT", 8456),
		PredictConcurrency: envInt("PREDICT_CONCURRENCY", 0),
		LogCaptureBodies:   envBool("LOG_CAPTURE_BODIES", true),
		LogQueueSize:       envInt("LOG_QUEUE_SIZE", 8192),
		LogFlushInterval:   envDuration("LOG_FLUSH_INTERVAL", 100*time.Millisecond),
		ShutdownDrain:      envDuration("SHUTDOWN_DRAIN", 10*time.Second),
		ServiceVersion:     os.Getenv("SERVICE_VERSION"),
	}
	c.ModelAPIKey = os.Getenv("MODEL_API_KEY")
	if c.ModelAPIKey == "" {
		return Config{}, fmt.Errorf("MODEL_API_KEY is required")
	}
	if c.Port < 1 || c.Port > 65535 {
		return Config{}, fmt.Errorf("invalid PORT: %d", c.Port)
	}
	return c, nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func envBool(k string, def bool) bool {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	switch v {
	case "1", "true", "yes", "TRUE":
		return true
	case "0", "false", "no", "FALSE":
		return false
	default:
		return def
	}
}

func envDuration(k string, def time.Duration) time.Duration {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	if ms, err := strconv.Atoi(v); err == nil {
		return time.Duration(ms) * time.Millisecond
	}
	return def
}
