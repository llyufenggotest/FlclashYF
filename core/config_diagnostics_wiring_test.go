package main

import (
	"os"
	"strings"
	"testing"
)

func TestConfigDiagnosticApplyStageWiring(t *testing.T) {
	data, err := os.ReadFile("common.go")
	if err != nil {
		t.Fatal(err)
	}
	source := string(data)
	start := strings.Index(source, "func applyConfig(")
	end := strings.Index(source[start:], "\nfunc UnmarshalJson")
	source = source[start : start+end]
	ordered := []string{
		"diagnostic := beginConfigDiagnostics()",
		"defer func() { diagnostic.record(configPhaseComplete, diagnosticSuccess) }()",
		"runtime.GC()", "configMu.Lock()", "defer configMu.Unlock()",
		"diagnostic.record(configPhaseLockAcquired, true)",
		"diagnostic.record(configPhaseParseBegin, true)", "cfg, err := loadConfig(",
		"diagnostic.record(configPhaseParseEnd, err == nil)",
		"if err != nil", "fallback, fallbackErr :=", "return err",
		"currentConfig = cfg", "diagnostic.record(configPhaseHubApplyBegin, true)",
		"hubErr := hub.ApplyConfig(cfg)", "diagnostic.record(configPhaseHubApplyEnd, hubErr == nil)",
		"diagnostic.record(configPhaseSelectionBegin, true)", "patchSelectGroup(params.SelectedMap)",
		"diagnostic.record(configPhaseSelectionEnd, true)",
		"diagnostic.record(configPhaseListenersBegin, true)", "updateListeners(cfg)",
		"diagnostic.record(configPhaseListenersEnd, true)", "reconcileGeoUpdater()",
		"diagnostic.record(configPhaseReclaimBegin, true)", "if features.WithLowMemory", "debug.FreeOSMemory()",
		"diagnostic.record(configPhaseReclaimEnd, true)", "diagnosticSuccess = err == nil && hubErr == nil", "return err",
	}
	remaining := source
	for _, token := range ordered {
		index := strings.Index(remaining, token)
		if index < 0 {
			t.Fatalf("missing or misordered apply stage: %s", token)
		}
		remaining = remaining[index+len(token):]
	}
	if strings.Contains(source, "return hubErr") {
		t.Fatal("diagnostics changed the ignored hub error behavior")
	}
}

func TestConfigDiagnosticPlatformAndBridgeWiring(t *testing.T) {
	checks := map[string][]string{
		"config_diagnostics_ios.go":     {"//go:build ios && cgo", "return newConfigDiagnosticRun(writeSystemLog)"},
		"config_diagnostics_stub.go":    {"//go:build !(ios && cgo)", "func (configDiagnostics) record(configDiagnosticPhase, bool) {}"},
		"../ios/NECore/NECoreBridge.m":  {"strcmp(level, \"diagnostic\") == 0", "NSClassFromString(@\"SwitchDiagnostics\")", "@selector(recordCorePhase:)", "methodForSelector:selector"},
		"../ios/Runner/IOSCoreBridge.m": {"strcmp(level, \"diagnostic\") == 0", "NSClassFromString(@\"SwitchDiagnostics\")", "@selector(recordCorePhase:)", "methodForSelector:selector"},
	}
	for path, tokens := range checks {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Error(err)
			continue
		}
		for _, token := range tokens {
			if !strings.Contains(string(data), token) {
				t.Errorf("%s missing %s", path, token)
			}
		}
	}
}
