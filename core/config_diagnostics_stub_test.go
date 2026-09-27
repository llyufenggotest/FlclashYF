//go:build !(ios && cgo)

package main

import "testing"

func TestConfigDiagnosticOtherPlatformsAreNoOp(t *testing.T) {
	before := configDiagnosticGeneration.Load()
	diagnostic := beginConfigDiagnostics()
	for phase := configPhaseBegin; phase <= configPhaseComplete; phase++ {
		diagnostic.record(phase, false)
	}
	if after := configDiagnosticGeneration.Load(); after != before {
		t.Fatalf("non-iOS diagnostics allocated generation: %d -> %d", before, after)
	}
}
