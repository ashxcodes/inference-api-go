package logging

import (
	"bufio"
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Meta struct {
	ServiceName string
	Environment string
	Version     string
	InstanceID  string
}

type AccessLogger struct {
	ch            chan accessRecord
	captureBodies bool
	dropped       atomic.Uint64
	onDrop        func()
	meta          Meta
	out           *bufio.Writer
	mu            sync.Mutex
	stop          chan struct{}
	done          chan struct{}
}

type accessRecord struct {
	rec      AccessRecord
	traceID  string
	spanID   string
}

type AccessRecord struct {
	Method       string
	URI          string
	HeadersJSON  string
	PostBody     string
	ClientIP     string
	ResponseCode int
	ResponseBody string
	TimeTaken    float64
}

func NewAccessLogger(queueSize int, captureBodies bool, flushInterval time.Duration, meta Meta, onDrop func()) *AccessLogger {
	l := &AccessLogger{
		ch:            make(chan accessRecord, queueSize),
		captureBodies: captureBodies,
		onDrop:        onDrop,
		meta:          meta,
		out:           bufio.NewWriter(os.Stdout),
		stop:          make(chan struct{}),
		done:          make(chan struct{}),
	}
	go l.writerLoop(flushInterval)
	return l
}

func (l *AccessLogger) Dropped() uint64 { return l.dropped.Load() }

func (l *AccessLogger) SetTraceContext(traceID, spanID string) {}

func (l *AccessLogger) LogAccess(r *http.Request, reqBody []byte, status int, respBody []byte, start time.Time, traceID, spanID string) {
	if strings.HasPrefix(strings.ToLower(r.URL.Path), "/health-check") {
		return
	}
	took := time.Since(start).Seconds()
	rec := AccessRecord{
		Method:       r.Method,
		URI:          r.URL.RequestURI(),
		ClientIP:     r.RemoteAddr,
		ResponseCode: status,
		TimeTaken:    took,
		HeadersJSON:  maskHeaders(r.Header),
	}
	if l.captureBodies {
		rec.PostBody = string(reqBody)
		rec.ResponseBody = string(respBody)
	} else {
		rec.PostBody = "[omitted: capture-disabled]"
		rec.ResponseBody = "[omitted: capture-disabled]"
	}
	select {
	case l.ch <- accessRecord{
		rec:     rec,
		traceID: traceID,
		spanID:  spanID,
	}:
	default:
		l.dropped.Add(1)
		if l.onDrop != nil {
			l.onDrop()
		}
	}
}

func (l *AccessLogger) Shutdown() {
	close(l.stop)
	<-l.done
}

func (l *AccessLogger) writerLoop(flushInterval time.Duration) {
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()
	defer close(l.done)

	for {
		select {
		case <-l.stop:
			for {
				select {
				case ar := <-l.ch:
					l.writeOne(ar)
				default:
					l.flush()
					return
				}
			}
		case ar := <-l.ch:
			l.writeOne(ar)
		case <-ticker.C:
			l.flush()
		}
	}
}

func (l *AccessLogger) writeOne(ar accessRecord) {
	rec := ar.rec
	ms := rec.TimeTaken * 1000
	m := map[string]any{
		"@timestamp":                 time.Now().UTC().Format(time.RFC3339Nano),
		"level":                      "INFO",
		"message":                    rec.Method + " " + rec.URI + " " + strconv.Itoa(rec.ResponseCode),
		"log.type":                   "access",
		"time_taken":                 rec.TimeTaken,
		"time_taken_in_milliseconds": ms,
		"request.method":             rec.Method,
		"request.uri":                rec.URI,
		"request.headers":            rec.HeadersJSON,
		"request.query":              "{}",
		"request.post":               rec.PostBody,
		"request.ip":                 rec.ClientIP,
		"response.response_code":     rec.ResponseCode,
		"response.content":             rec.ResponseBody,
		"service.name":               l.meta.ServiceName,
		"deployment.environment":     l.meta.Environment,
		"service.version":            l.meta.Version,
		"service.instance.id":        l.meta.InstanceID,
	}
	if ar.traceID != "" {
		m["trace_id"] = ar.traceID
		m["span_id"] = ar.spanID
	}
	m["message"] = rec.Method + " " + pathFromURI(rec.URI) + " " + strconv.Itoa(rec.ResponseCode) + " " + strconv.FormatFloat(ms, 'f', 0, 64) + "ms"
	b, _ := json.Marshal(m)
	l.mu.Lock()
	_, _ = l.out.Write(b)
	_ = l.out.WriteByte('\n')
	l.mu.Unlock()
}

func pathFromURI(uri string) string {
	if i := strings.Index(uri, "?"); i >= 0 {
		return uri[:i]
	}
	return uri
}

func (l *AccessLogger) flush() {
	l.mu.Lock()
	_ = l.out.Flush()
	l.mu.Unlock()
}

func maskHeaders(h http.Header) string {
	cp := make(map[string][]string)
	for k, v := range h {
		if strings.EqualFold(k, "x-api-key") {
			cp[k] = []string{"***"}
			continue
		}
		cp[k] = v
	}
	b, _ := json.Marshal(cp)
	return string(b)
}
