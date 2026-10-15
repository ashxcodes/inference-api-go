package config

import (
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestLoadRequiresAPIKey(t *testing.T) {
	os.Unsetenv("MODEL_API_KEY")
	_, err := Load()
	require.Error(t, err)
}

func TestLoadOK(t *testing.T) {
	os.Setenv("MODEL_API_KEY", "k")
	defer os.Unsetenv("MODEL_API_KEY")
	c, err := Load()
	require.NoError(t, err)
	require.Equal(t, 8456, c.Port)
}
