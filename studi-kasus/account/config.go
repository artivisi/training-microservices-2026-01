package main

import (
	"fmt"
	"os"
	"strings"
)

// Config comes from environment variables only (12-factor). Every variable is
// required: a missing value stops the service at startup instead of running
// with a guessed default.
type Config struct {
	HTTPAddr    string
	DatabaseURL string
}

func LoadConfig() (Config, error) {
	var missing []string
	get := func(name string) string {
		v := os.Getenv(name)
		if v == "" {
			missing = append(missing, name)
		}
		return v
	}
	cfg := Config{
		HTTPAddr:    get("HTTP_ADDR"),
		DatabaseURL: get("DATABASE_URL"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}
	return cfg, nil
}
