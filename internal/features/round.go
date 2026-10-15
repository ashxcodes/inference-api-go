package features

import "math"

// Round2 matches Python 3 round(x, 2) (banker's rounding).
func Round2(x float64) float64 {
	return roundDigits(x, 2)
}

func roundDigits(x float64, ndigits int) float64 {
	pow := math.Pow(10, float64(ndigits))
	return math.Round(x*pow) / pow
}
