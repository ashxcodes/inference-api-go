package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// FlexFloat accepts JSON number or numeric string (Pydantic-like). JSON null is an error.
type FlexFloat float64

func (f *FlexFloat) UnmarshalJSON(b []byte) error {
	if bytes.Equal(bytes.TrimSpace(b), []byte("null")) {
		return fmt.Errorf("null")
	}
	if len(b) > 0 && b[0] == '"' {
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		v, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return err
		}
		*f = FlexFloat(v)
		return nil
	}
	var v float64
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	*f = FlexFloat(v)
	return nil
}

var predictFieldNames = []string{
	"city", "key", "origin_lat", "origin_lng", "waypoint_lat", "waypoint_lng",
	"destination_lat", "destination_lng", "created_at",
}

var predictFieldSet = func() map[string]struct{} {
	m := make(map[string]struct{}, len(predictFieldNames))
	for _, k := range predictFieldNames {
		m[k] = struct{}{}
	}
	return m
}()

type predictRequest struct {
	City           string     `json:"city"`
	Key            string     `json:"key"`
	OriginLat      FlexFloat  `json:"origin_lat"`
	OriginLng      FlexFloat  `json:"origin_lng"`
	WaypointLat    *FlexFloat `json:"waypoint_lat"`
	WaypointLng    *FlexFloat `json:"waypoint_lng"`
	DestinationLat FlexFloat  `json:"destination_lat"`
	DestinationLng FlexFloat  `json:"destination_lng"`
	CreatedAt      string     `json:"created_at"`
}

func decodePredictRequest(body []byte) (predictRequest, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	var raw map[string]json.RawMessage
	if err := dec.Decode(&raw); err != nil {
		return predictRequest{}, err
	}
	if trailing := strings.TrimSpace(string(body[dec.InputOffset():])); trailing != "" {
		return predictRequest{}, fmt.Errorf("trailing data")
	}
	if err := validatePredictKeys(raw); err != nil {
		return predictRequest{}, err
	}
	required := []string{
		"city", "key", "origin_lat", "origin_lng", "destination_lat", "destination_lng", "created_at",
	}
	for _, k := range required {
		if err := requireJSONValue(raw, k); err != nil {
			return predictRequest{}, err
		}
	}
	var req predictRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return predictRequest{}, err
	}
	if _, ok := raw["created_at"]; ok {
		var created string
		if err := json.Unmarshal(raw["created_at"], &created); err != nil {
			return predictRequest{}, fmt.Errorf("created_at type")
		}
		req.CreatedAt = created
	}
	return req, nil
}

func validatePredictKeys(raw map[string]json.RawMessage) error {
	lowerToCanon := make(map[string]string, len(predictFieldNames))
	for _, k := range predictFieldNames {
		lowerToCanon[strings.ToLower(k)] = k
	}
	for k := range raw {
		if _, ok := predictFieldSet[k]; ok {
			continue
		}
		if canon, ok := lowerToCanon[strings.ToLower(k)]; ok && canon != k {
			return fmt.Errorf("wrong field case")
		}
	}
	return nil
}

func requireJSONValue(raw map[string]json.RawMessage, key string) error {
	v, ok := raw[key]
	if !ok {
		return fmt.Errorf("missing %s", key)
	}
	if bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
		return fmt.Errorf("null %s", key)
	}
	return nil
}

func encodePredictResponse(key string, eta, distance float64) ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteString("{\"key\":")
	encKey, _ := json.Marshal(key)
	buf.Write(encKey)
	buf.WriteString(",\"eta\":")
	buf.Write(pythonFloatJSON(eta))
	buf.WriteString(",\"distance\":")
	buf.Write(pythonFloatJSON(distance))
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

func pythonFloatJSON(v float64) []byte {
	s := strconv.FormatFloat(v, 'f', -1, 64)
	if !containsDotOrExp(s) {
		s += ".0"
	}
	return []byte(s)
}

func containsDotOrExp(s string) bool {
	for _, c := range s {
		if c == '.' || c == 'e' || c == 'E' {
			return true
		}
	}
	return false
}
