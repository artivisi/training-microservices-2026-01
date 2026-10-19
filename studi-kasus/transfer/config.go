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
	// AccountGRPCAddr is host:port of the account service's gRPC API.
	AccountGRPCAddr string
	// KafkaBrokers is a comma-separated list of host:port.
	KafkaBrokers []string
	KafkaTopic   string
	// Lab 7, as resource server (the REST API): OAuthIssuer must equal the "iss"
	// claim of the tokens character for character; OAuthJWKSURL serves the
	// authorization server's public keys.
	OAuthIssuer  string
	OAuthJWKSURL string
	// Lab 7, as OAuth2 client (calling account over gRPC): client credentials
	// grant against OAuthTokenURL. The secret belongs in a Kubernetes Secret or
	// a vault, never in the image or the repository (Lab 9).
	OAuthClientID     string
	OAuthClientSecret string
	OAuthTokenURL     string
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
		HTTPAddr:          get("HTTP_ADDR"),
		DatabaseURL:       get("DATABASE_URL"),
		AccountGRPCAddr:   get("ACCOUNT_GRPC_ADDR"),
		KafkaBrokers:      strings.Split(get("KAFKA_BROKERS"), ","),
		KafkaTopic:        get("KAFKA_TOPIC"),
		OAuthIssuer:       get("OAUTH_ISSUER"),
		OAuthJWKSURL:      get("OAUTH_JWKS_URL"),
		OAuthClientID:     get("OAUTH_CLIENT_ID"),
		OAuthClientSecret: get("OAUTH_CLIENT_SECRET"),
		OAuthTokenURL:     get("OAUTH_TOKEN_URL"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}
	return cfg, nil
}
