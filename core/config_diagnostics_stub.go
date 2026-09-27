//go:build !(ios && cgo)

package main

type configDiagnostics struct{}

func beginConfigDiagnostics() configDiagnostics {
	return configDiagnostics{}
}

func (configDiagnostics) record(configDiagnosticPhase, bool) {}
