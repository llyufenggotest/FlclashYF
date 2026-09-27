package main

import (
	"encoding/json"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
)

func TestConfigDiagnosticPhasesAreClosedAndPayloadFree(t *testing.T) {
	want := []string{
		"apply_config_begin", "apply_config_lock_acquired",
		"apply_config_parse_begin", "apply_config_parse_end",
		"apply_config_hub_apply_begin", "apply_config_hub_apply_end",
		"apply_config_selection_begin", "apply_config_selection_end",
		"apply_config_listeners_begin", "apply_config_listeners_end",
		"apply_config_reclaim_begin", "apply_config_reclaim_end", "apply_config_complete",
	}
	for phase := 0; phase < 256; phase++ {
		message := configDiagnosticJSON(configDiagnosticPhase(phase), true, 0, 0, runtime.MemStats{}, 1)
		if phase >= len(want) {
			if message != "" {
				t.Fatalf("unknown phase %d accepted: %s", phase, message)
			}
			continue
		}
		var record map[string]any
		if err := json.Unmarshal([]byte(message), &record); err != nil {
			t.Fatal(err)
		}
		if record["core_phase"] != want[phase] || record["success"] != true {
			t.Fatalf("unexpected phase record: %v", record)
		}
		for key, value := range record {
			if _, ok := value.(string); ok && key != "core_phase" {
				t.Fatalf("raw text field accepted: %s", key)
			}
		}
	}
}

func TestConfigDiagnosticRunSamplesAndKeepsGeneration(t *testing.T) {
	var records []map[string]any
	run := newConfigDiagnosticRun(func(level, message string) {
		if level != "diagnostic" || strings.Contains(message, "secret") {
			t.Fatalf("unsafe bridge message: %s %s", level, message)
		}
		var record map[string]any
		if err := json.Unmarshal([]byte(message), &record); err != nil {
			t.Fatal(err)
		}
		records = append(records, record)
	})
	run.record(configPhaseHubApplyEnd, false)
	run.record(configPhaseComplete, false)
	if len(records) != 3 {
		t.Fatalf("record count = %d", len(records))
	}
	for _, record := range records {
		if record["heap_alloc_bytes"].(float64) <= 0 || record["heap_sys_bytes"].(float64) <= 0 || record["goroutines"].(float64) < 1 {
			t.Fatalf("missing runtime sample: %v", record)
		}
		if record["config_generation"] != records[0]["config_generation"] || record["elapsed_ms"].(float64) < 0 {
			t.Fatalf("invalid correlation: %v", record)
		}
	}
	if records[0]["core_phase"] != "apply_config_begin" || records[2]["success"] != false {
		t.Fatalf("invalid lifecycle: %v", records)
	}
}

func TestConfigDiagnosticConcurrentGenerationsAreUnique(t *testing.T) {
	const count = 16
	generations := make(chan uint64, count)
	var wg sync.WaitGroup
	for range count {
		wg.Go(func() {
			run := newConfigDiagnosticRun(func(string, string) {})
			generations <- run.generation
		})
	}
	wg.Wait()
	close(generations)
	seen := make(map[uint64]bool)
	for generation := range generations {
		if generation == 0 || seen[generation] {
			t.Fatalf("invalid generation: %d", generation)
		}
		seen[generation] = true
	}
}

func TestConfigDiagnosticFixedSchema(t *testing.T) {
	message := configDiagnosticJSON(configPhaseHubApplyEnd, false, 7, 12,
		runtime.MemStats{HeapAlloc: 101, HeapSys: 202, NumGC: 3}, 4)
	var record map[string]any
	if err := json.Unmarshal([]byte(message), &record); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(record))
	for key := range record {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	wantKeys := []string{"config_generation", "core_phase", "elapsed_ms", "goroutines", "heap_alloc_bytes", "heap_sys_bytes", "num_gc", "success"}
	if !reflect.DeepEqual(keys, wantKeys) {
		t.Fatalf("unexpected diagnostic fields: %v", keys)
	}
	want := map[string]any{
		"core_phase": "apply_config_hub_apply_end", "success": false,
		"config_generation": float64(7), "elapsed_ms": float64(12),
		"heap_alloc_bytes": float64(101), "heap_sys_bytes": float64(202),
		"num_gc": float64(3), "goroutines": float64(4),
	}
	if !reflect.DeepEqual(record, want) {
		t.Fatalf("record = %v, want %v", record, want)
	}
}
