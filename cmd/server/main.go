package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	_ "time/tzdata"

	"github.com/jeenyme/ml-model-go/internal/config"
	"github.com/jeenyme/ml-model-go/internal/eta"
	"github.com/jeenyme/ml-model-go/internal/features"
	"github.com/jeenyme/ml-model-go/internal/httpapi"
	"github.com/jeenyme/ml-model-go/internal/inference"
	"github.com/jeenyme/ml-model-go/internal/logging"
	"github.com/jeenyme/ml-model-go/internal/telemetry"
)

var version = "dev"

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	telemetry.Start()
	if os.Getenv("OTEL_SDK_DISABLED") != "true" {
		log.Printf(
			"otel: endpoint=%s protocol=%s traces=%s metrics=%s",
			os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
			envOrDefault("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc"),
			envOrDefault("OTEL_TRACES_EXPORTER", "otlp"),
			envOrDefault("OTEL_METRICS_EXPORTER", "otlp"),
		)
	}
	telemetry.StartSystemMetrics()

	models, err := inference.LoadModels(cfg.ModelDir)
	if err != nil {
		log.Fatalf("models: %v", err)
	}
	predictor := inference.NewPool(cfg.ModelDir, models, cfg.PredictConcurrency)

	etaSvc := eta.Service{
		Transform: features.Transform{},
		Predictor: predictor,
		Clock:     eta.SystemClock{},
	}

	meta := logging.Meta{
		ServiceName: os.Getenv("OTEL_SERVICE_NAME"),
		Environment: os.Getenv("APP_ENV"),
		Version:     version,
		InstanceID:  os.Getenv("HOSTNAME"),
	}
	accessLog := logging.NewAccessLogger(cfg.LogQueueSize, cfg.LogCaptureBodies, cfg.LogFlushInterval, meta, nil)

	var ready atomic.Bool
	ready.Store(true)

	srv := httpapi.NewServer(cfg, etaSvc, accessLog, func() bool { return ready.Load() })
	serviceName := envOrDefault("OTEL_SERVICE_NAME", "ml-model-go")
	handler := telemetry.InstrumentHandler(serviceName, srv.Handler())

	httpSrv := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.Port),
		Handler:      handler,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  75 * time.Second,
	}

	go func() {
		log.Printf("listening on :%d", cfg.Port)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server: %v", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig

	ready.Store(false)
	time.Sleep(cfg.ShutdownDrain)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), telemetry.FlushTimeout())
	defer cancel()
	_ = telemetry.Shutdown(shutdownCtx)
	accessLog.Shutdown()
	_ = httpSrv.Shutdown(shutdownCtx)
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
