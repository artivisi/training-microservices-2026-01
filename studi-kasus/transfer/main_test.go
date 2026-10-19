package main

import (
	"testing"
	"time"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/accountclient"
)

// TestShutdownGrace keeps shutdownGrace in step with the resiliency policies: a
// longer retry or reversal window must come with a longer shutdown wait.
func TestShutdownGrace(t *testing.T) {
	const dbMargin = 3 * time.Second
	if need := accountclient.ProductionSettings.WorstCaseSaga() + dbMargin; shutdownGrace < need {
		t.Fatalf("shutdownGrace = %s, want at least %s (worst-case saga + %s)", shutdownGrace, need, dbMargin)
	}
}
