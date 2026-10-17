package telemetry

import (
	"context"
	"log"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"go.opentelemetry.io/contrib/exporters/autoexport"
	"go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/contrib/propagators/autoprop"
	"go.opentelemetry.io/otel"
	logglobal "go.opentelemetry.io/otel/log/global"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
)

const (
	traceBatchTimeout = time.Second
	traceBatchSize    = 512
)

var (
	tracerProvider *sdktrace.TracerProvider
	meterProvider  *sdkmetric.MeterProvider
	loggerProvider *sdklog.LoggerProvider
)

// Start configures the global OpenTelemetry SDK from OTEL_* environment variables.
// No-op when OTEL_SDK_DISABLED=true.
func Start() {
	if sdkDisabled() {
		return
	}

	ctx := context.Background()

	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		log.Printf("telemetry: sdk error: %v", err)
	}))

	res, err := resource.New(ctx,
		resource.WithProcess(),
		resource.WithOS(),
		resource.WithContainer(),
		resource.WithHost(),
		resource.WithFromEnv(),
		resource.WithAttributes(semconv.ServiceInstanceID(serviceInstanceID())),
	)
	if err != nil {
		log.Printf("telemetry: resource: %v", err)
		res = resource.Default()
	}

	if err := setupTraceProvider(ctx, res); err != nil {
		log.Printf("telemetry: traces: %v", err)
	}
	if err := setupMeterProvider(ctx, res); err != nil {
		log.Printf("telemetry: metrics: %v", err)
	}
	if err := setupLoggerProvider(ctx, res); err != nil {
		log.Printf("telemetry: logs: %v", err)
	}

	otel.SetTextMapPropagator(autoprop.NewTextMapPropagator())
	startRuntimeMetrics()
}

func setupTraceProvider(ctx context.Context, res *resource.Resource) error {
	exporter, err := autoexport.NewSpanExporter(ctx)
	if err != nil {
		return err
	}
	if autoexport.IsNoneSpanExporter(exporter) {
		return nil
	}

	processor := sdktrace.NewBatchSpanProcessor(exporter,
		sdktrace.WithBatchTimeout(traceBatchTimeout),
		sdktrace.WithMaxExportBatchSize(traceBatchSize),
	)
	if strings.EqualFold(strings.TrimSpace(os.Getenv("OTEL_GO_SIMPLE_SPAN_PROCESSOR")), "true") {
		processor = sdktrace.NewSimpleSpanProcessor(exporter)
	}

	tracerProvider = sdktrace.NewTracerProvider(
		sdktrace.WithResource(res),
		sdktrace.WithSpanProcessor(processor),
	)
	otel.SetTracerProvider(tracerProvider)
	return nil
}

func setupMeterProvider(ctx context.Context, res *resource.Resource) error {
	reader, err := autoexport.NewMetricReader(ctx)
	if err != nil {
		return err
	}
	if autoexport.IsNoneMetricReader(reader) {
		return nil
	}

	meterProvider = sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(reader),
	)
	otel.SetMeterProvider(meterProvider)
	return nil
}

func setupLoggerProvider(ctx context.Context, res *resource.Resource) error {
	exporter, err := autoexport.NewLogExporter(ctx)
	if err != nil {
		return err
	}
	if autoexport.IsNoneLogExporter(exporter) {
		return nil
	}

	loggerProvider = sdklog.NewLoggerProvider(
		sdklog.WithResource(res),
		sdklog.WithProcessor(sdklog.NewBatchProcessor(exporter)),
	)
	logglobal.SetLoggerProvider(loggerProvider)
	return nil
}

func startRuntimeMetrics() {
	if !runtimeMetricsEnabled() {
		return
	}
	if err := runtime.Start(runtime.WithMeterProvider(otel.GetMeterProvider())); err != nil {
		log.Printf("telemetry: runtime metrics disabled: %v", err)
		return
	}
	log.Print("telemetry: runtime metrics enabled (go_*)")
}

func sdkDisabled() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("OTEL_SDK_DISABLED")), "true")
}

// serviceInstanceID returns HOSTNAME when set (pod name on Kubernetes), otherwise a UUID.
func serviceInstanceID() string {
	if host := strings.TrimSpace(os.Getenv("HOSTNAME")); host != "" {
		return host
	}
	return uuid.NewString()
}

func runtimeMetricsEnabled() bool {
	if sdkDisabled() {
		return false
	}
	if v := strings.TrimSpace(os.Getenv("OTEL_GO_RUNTIME_METRICS")); v != "" {
		switch strings.ToLower(v) {
		case "0", "false", "no":
			return false
		default:
			return true
		}
	}
	if list := strings.TrimSpace(os.Getenv("OTEL_GO_ENABLED_INSTRUMENTATIONS")); list != "" {
		if !instrumentationListed(list, "runtimemetrics") {
			return false
		}
	}
	if list := strings.TrimSpace(os.Getenv("OTEL_GO_DISABLED_INSTRUMENTATIONS")); list != "" {
		if instrumentationListed(list, "runtimemetrics") {
			return false
		}
	}
	exporter := strings.ToLower(strings.TrimSpace(os.Getenv("OTEL_METRICS_EXPORTER")))
	return exporter != "" && exporter != "none"
}

func instrumentationListed(csv, name string) bool {
	name = strings.ToLower(name)
	for item := range strings.SplitSeq(csv, ",") {
		if strings.ToLower(strings.TrimSpace(item)) == name {
			return true
		}
	}
	return false
}
