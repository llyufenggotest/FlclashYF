package main

import (
	"github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"testing"
)

type retainedLifecycleProvider struct {
	P.ProxyProvider
	closes int
}

func (p *retainedLifecycleProvider) Close() error { p.closes++; return nil }

func TestReleaseAndShutdownRetireProxyRuntime(t *testing.T) {
	for _, tc := range []struct {
		name string
		stop func() bool
	}{{"release", handleReleaseConfig}, {"shutdown", handleShutdown}} {
		t.Run(tc.name, func(t *testing.T) {
			p := &retainedLifecycleProvider{ProxyProvider: newCachingProvider("retained", "node")}
			tunnel.UpdateProxies(map[string]constant.Proxy{"node": namedProxy("node")}, map[string]P.ProxyProvider{"retained": p})
			t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
			_ = tunnel.AllProxies()
			if !tc.stop() {
				t.Fatal("stop failed")
			}
			if p.closes != 1 || len(tunnel.ProvidersSnapshot()) != 0 || len(tunnel.Proxies()) != 0 {
				t.Fatalf("stop retained proxy runtime: closes=%d providers=%d proxies=%d", p.closes, len(tunnel.ProvidersSnapshot()), len(tunnel.Proxies()))
			}
		})
	}
}
