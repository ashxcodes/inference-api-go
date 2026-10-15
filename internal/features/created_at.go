package features

import (
	"fmt"
	"strings"
	"time"
)

// ParseCreatedAt parses created_at for known callers (location-engine + legacy ml-model shapes).
//
// location-engine (production) sets dispatch.dt via:
//   now_ast.strftime("%Y-%m-%d %H:%M:%S.%f")
// i.e. wall-clock Asia/Riyadh with optional microsecond fraction, no timezone suffix.
//
// Also accepts the older "… UTC" fractional form seen in docs/golden tests.
func ParseCreatedAt(s string) (time.Time, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, fmt.Errorf("unparseable created_at: %q", s)
	}

	if strings.HasSuffix(s, " UTC") {
		core := strings.TrimSpace(strings.TrimSuffix(s, " UTC"))
		t, err := parseLocalLayouts(core)
		if err != nil {
			return time.Time{}, fmt.Errorf("unparseable created_at: %q", s)
		}
		return t, nil
	}

	t, err := parseLocalLayouts(s)
	if err != nil {
		return time.Time{}, fmt.Errorf("unparseable created_at: %q", s)
	}
	return t, nil
}

func parseLocalLayouts(s string) (time.Time, error) {
	// Order: microsecond fraction first (location-engine), then second precision.
	layouts := []string{
		"2006-01-02 15:04:05.999999",
		"2006-01-02 15:04:05",
	}
	for _, layout := range layouts {
		if t, err := time.ParseInLocation(layout, s, time.UTC); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("layout")
}

// PandasDayOfWeek returns Monday=0 .. Sunday=6 (matches pandas dayofweek).
func PandasDayOfWeek(t time.Time) int {
	return (int(t.Weekday()) + 6) % 7
}
