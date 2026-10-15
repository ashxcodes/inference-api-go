package logging

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestEnqueueDoesNotBlockWhenFull(t *testing.T) {
	l := NewAccessLogger(1, false, time.Hour, Meta{}, nil)
	req := httptest.NewRequest("POST", "/predict", nil)
	for i := 0; i < 5000; i++ {
		l.LogAccess(req, []byte("{}"), 200, []byte("{}"), time.Now(), "", "")
	}
	require.GreaterOrEqual(t, l.Dropped(), uint64(1))
}
