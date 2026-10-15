// Package lgbm loads LightGBM .txt models and runs inference (pure Go via go-lgbm).
package lgbm

import (
	"fmt"

	golgbm "github.com/zhongdai/go-lgbm"
)

const ExpectedFeatures = 9

type Booster struct {
	model *golgbm.Model
}

func LoadFromFile(path string) (*Booster, error) {
	m, err := golgbm.ModelFromFile(path, true)
	if err != nil {
		return nil, err
	}
	if m.NFeatures() != ExpectedFeatures {
		return nil, fmt.Errorf("model has %d features, expected %d", m.NFeatures(), ExpectedFeatures)
	}
	return &Booster{model: m}, nil
}

func (b *Booster) PredictRow(features []float64) (float64, error) {
	if len(features) != ExpectedFeatures {
		return 0, fmt.Errorf("expected %d features, got %d", ExpectedFeatures, len(features))
	}
	return b.model.PredictSingle(features, 0)
}
