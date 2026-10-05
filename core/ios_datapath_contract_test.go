package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func readRepoFile(t *testing.T, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.FromSlash(rel))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return strings.ReplaceAll(string(data), "\r\n", "\n")
}

func TestStartTunReportsRealResult(t *testing.T) {
	src := readRepoFile(t, "lib.go")

	if !strings.Contains(src, "started := handleStartTun(callback, int(fd), options)") {
		t.Error("startTUN must capture handleStartTun's result")
	}
	if !strings.Contains(src, "return started") {
		t.Error("startTUN must return the propagated result")
	}

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

	if !strings.Contains(src, "func handleStartTun(callback unsafe.Pointer, fd int, options t.Options) bool") {
		t.Error("handleStartTun must return bool")
	}
	if !strings.Contains(src, "func (th *TunHandler) start(fd int, options t.Options) bool") {
		t.Error("TunHandler.start must return bool")
	}
	if !strings.Contains(src, "TUN: refusing to start with fd=0") {
		t.Error("handleStartTun must reject fd=0 explicitly")
	}
}

func TestRuleProviderFirstFetchIsDeferredOnIOSExtension(t *testing.T) {
	exec := readRepoFile(t, filepath.Join("mihomo", "hub", "executor", "executor.go"))

	if !strings.Contains(exec, "loadRuleProviders(cfg.RuleProviders)") {
		t.Error("ApplyConfig must route rule providers through loadRuleProviders")
	}
	if strings.Contains(exec, "loadProvider(cfg.RuleProviders)") {
		t.Error("ApplyConfig still calls loadProvider(cfg.RuleProviders) directly")
	}
	if !strings.Contains(exec, "loadProvider(cfg.Providers)") {
		t.Error("proxy providers must still load synchronously")
	}
	if !strings.Contains(exec, "func loadRuleProviders[T P.Provider]") {
		t.Error("loadRuleProviders must exist")
	}
	if !strings.Contains(exec, "go loadProvider(providers)") {
		t.Error("loadRuleProviders must dispatch asynchronously when gated")
	}

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
