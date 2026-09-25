package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Contract test for the two root causes found in the 2026-08-29 23:39 device
// trace. Both are cross-layer honesty/ordering bugs that no unit test could
// catch, so the guard is at source level.
//
// 1. `startTUN` returned an unconditional `true`. The trace caught
//    `TUN: dup fd: bad file descriptor` followed by `startTun result=true`, so
//    Swift skipped `rollbackPartialStart` and the tunnel showed "connected" with
//    no data path.
// 2. Remote rule providers were fetched synchronously while `runLock` was held,
//    and `startTUN` needs that lock, so the data path waited 24-25 s for 24
//    providers that could not resolve DNS until the data path existed.

func readRepoFile(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.FromSlash(rel))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	// The checkout carries CRLF on Windows; normalise so line-anchored patterns
	// and body delimiters behave the same locally and on the Linux runner.
	return strings.ReplaceAll(string(data), "\r\n", "\n")
}

func TestStartTunReportsRealResult(t *testing.T) {
	src := readRepoFile(t, "lib.go")

	// The exported entrypoint must return the propagated result, never a literal.
	if !strings.Contains(src, "started := handleStartTun(callback, int(fd), options)") {
		t.Error("startTUN must capture handleStartTun's result")
	}
	if !strings.Contains(src, "return started") {
		t.Error("startTUN must return the propagated result")
	}

	// Reverse assertion: the old unconditional success must be gone. Scope the
	// search to the startTUN body so unrelated `return true` elsewhere is fine.
	start := strings.Index(src, "func startTUN(")
	if start < 0 {
		t.Fatal("startTUN not found")
	}
	end := strings.Index(src[start:], "\n}\n")
	if end < 0 {
		t.Fatal("startTUN body not delimited")
	}
	body := src[start : start+end]
	if regexp.MustCompile(`(?m)^\treturn true$`).MatchString(body) {
		t.Error("startTUN still has an unconditional `return true`")
	}

	// Both helpers must be boolean-valued for the result to propagate at all.
	if !strings.Contains(src, "func handleStartTun(callback unsafe.Pointer, fd int, options t.Options) bool") {
		t.Error("handleStartTun must return bool")
	}
	if !strings.Contains(src, "func (th *TunHandler) start(fd int, options t.Options) bool") {
		t.Error("TunHandler.start must return bool")
	}
	// An fd of 0 is not a usable descriptor and must be reported as failure.
	if !strings.Contains(src, "TUN: refusing to start with fd=0") {
		t.Error("handleStartTun must reject fd=0 explicitly")
	}
}

func TestRuleProviderFirstFetchIsDeferredOnIOSExtension(t *testing.T) {
	exec := readRepoFile(t, filepath.Join("mihomo", "hub", "executor", "executor.go"))

	// ApplyConfig must call the gated wrapper, not loadProvider directly, for
	// rule providers.
	if !strings.Contains(exec, "loadRuleProviders(cfg.RuleProviders)") {
		t.Error("ApplyConfig must route rule providers through loadRuleProviders")
	}
	if strings.Contains(exec, "loadProvider(cfg.RuleProviders)") {
		t.Error("ApplyConfig still calls loadProvider(cfg.RuleProviders) directly")
	}
	// Proxy providers stay synchronous: groups reference them immediately.
	if !strings.Contains(exec, "loadProvider(cfg.Providers)") {
		t.Error("proxy providers must still load synchronously")
	}
	if !strings.Contains(exec, "func loadRuleProviders[T P.Provider]") {
		t.Error("loadRuleProviders must exist")
	}
	if !strings.Contains(exec, "go loadProvider(providers)") {
		t.Error("loadRuleProviders must dispatch asynchronously when gated")
	}

	// The gate must be a build-tagged constant with both variants present, so
	// only the iOS Network Extension defers.
	iosVariant := readRepoFile(t, filepath.Join(
		"mihomo", "hub", "executor", "rule_provider_defer_ios_lowmem.go"))
	if !strings.Contains(iosVariant, "//go:build ios && with_low_memory") {
		t.Error("iOS variant must be tagged `ios && with_low_memory`")
	}
	if !strings.Contains(iosVariant, "deferRuleProviderInitial = true") {
		t.Error("iOS extension variant must defer")
	}

	defaultVariant := readRepoFile(t, filepath.Join(
		"mihomo", "hub", "executor", "rule_provider_defer_default.go"))
	if !strings.Contains(defaultVariant, "//go:build !(ios && with_low_memory)") {
		t.Error("default variant must carry the negated build tag")
	}
	if !strings.Contains(defaultVariant, "deferRuleProviderInitial = false") {
		t.Error("non-iOS builds must keep the synchronous first fetch")
	}
}
