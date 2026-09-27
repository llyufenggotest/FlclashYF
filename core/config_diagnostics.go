package main

import (
	"encoding/json"
	"runtime"
	"sync/atomic"
	"time"
)

var configDiagnosticGeneration atomic.Uint64

type configDiagnosticRun struct {
	generation uint64
	started    time.Time
	write      func(string, string)
}

func newConfigDiagnosticRun(write func(string, string)) configDiagnosticRun {
	run := configDiagnosticRun{
		generation: configDiagnosticGeneration.Add(1),
		started:    time.Now(),
		write:      write,
	}
	run.record(configPhaseBegin, true)
	return run
}

func (run configDiagnosticRun) record(phase configDiagnosticPhase, success bool) {
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	message := configDiagnosticJSON(phase, success, run.generation, time.Since(run.started).Milliseconds(), memory, runtime.NumGoroutine())
	if message != "" {
		run.write("diagnostic", message)
	}
}

type configDiagnosticPhase uint8

const (
	configPhaseBegin configDiagnosticPhase = iota
	configPhaseLockAcquired
	configPhaseParseBegin
	configPhaseParseEnd
	configPhaseHubApplyBegin
	configPhaseHubApplyEnd
	configPhaseSelectionBegin
	configPhaseSelectionEnd
	configPhaseListenersBegin
	configPhaseListenersEnd
	configPhaseReclaimBegin
	configPhaseReclaimEnd
	configPhaseComplete
)

func configDiagnosticJSON(phase configDiagnosticPhase, success bool, generation uint64, elapsedMS int64, memory runtime.MemStats, goroutines int) string {
	phases := [...]string{
		"apply_config_begin",
		"apply_config_lock_acquired",
		"apply_config_parse_begin",
		"apply_config_parse_end",
		"apply_config_hub_apply_begin",
		"apply_config_hub_apply_end",
		"apply_config_selection_begin",
		"apply_config_selection_end",
		"apply_config_listeners_begin",
		"apply_config_listeners_end",
		"apply_config_reclaim_begin",
		"apply_config_reclaim_end",
		"apply_config_complete",
	}
	if int(phase) >= len(phases) {
		return ""
	}
	record := struct {
		CorePhase        string `json:"core_phase"`
		Success          bool   `json:"success"`
		HeapAllocBytes   uint64 `json:"heap_alloc_bytes"`
		HeapSysBytes     uint64 `json:"heap_sys_bytes"`
		NumGC            uint32 `json:"num_gc"`
		Goroutines       int    `json:"goroutines"`
		ElapsedMS        int64  `json:"elapsed_ms"`
		ConfigGeneration uint64 `json:"config_generation"`
	}{phases[phase], success, memory.HeapAlloc, memory.HeapSys, memory.NumGC, goroutines, elapsedMS, generation}
	data, err := json.Marshal(record)
	if err != nil {
		return ""
	}
	return string(data)
}
