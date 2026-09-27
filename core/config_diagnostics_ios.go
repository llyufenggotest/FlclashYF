//go:build ios && cgo

package main

func beginConfigDiagnostics() configDiagnosticRun {
	return newConfigDiagnosticRun(writeSystemLog)
}
