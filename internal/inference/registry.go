package inference

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ashxcodes/inference-api-go/internal/lgbm"
)

type Model struct {
	City    string
	Path    string
	Booster *lgbm.Booster
}

func LoadModels(dir string) (map[string]*Model, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	models := make(map[string]*Model)
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".txt") {
			continue
		}
		city := strings.TrimSuffix(e.Name(), ".txt")
		path := filepath.Join(dir, city+".txt")
		b, err := lgbm.LoadFromFile(path)
		if err != nil {
			return nil, fmt.Errorf("load %s: %w", path, err)
		}
		models[city] = &Model{City: city, Path: path, Booster: b}
	}
	if len(models) == 0 {
		return nil, fmt.Errorf("no models loaded from %s", dir)
	}
	return models, nil
}

type NotFoundError struct {
	City string
	Dir  string
}

func (e NotFoundError) Error() string {
	return fmt.Sprintf("Model file not found for city %s - Path: %s/%s.txt", e.City, e.Dir, e.City)
}

type PredictError struct {
	City string
	Err  error
}

func (e PredictError) Error() string {
	return fmt.Sprintf("Prediction failed for model '%s': %v", e.City, e.Err)
}

func (e PredictError) Unwrap() error { return e.Err }
