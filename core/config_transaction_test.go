package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/features"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
)

type closeTrackedProxy struct {
	constant.Proxy
	closes int
}

func (p *closeTrackedProxy) Close() error { p.closes++; return nil }

type closeTrackedProvider struct {
	cp.ProxyProvider
	proxies []constant.Proxy
	closes  int
}

func (p *closeTrackedProvider) Name() string              { return "tracked" }
func (p *closeTrackedProvider) Close() error              { p.closes++; return nil }
func (p *closeTrackedProvider) Proxies() []constant.Proxy { return p.proxies }
func (p *closeTrackedProvider) Version() uint32           { return 0 }

func TestApplyConfigClosesOnlyRejectedCandidateResources(t *testing.T) {
	home := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(home) })
	if err := os.WriteFile(filepath.Join(constant.Path.HomeDir(), "config.yaml"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	activeProxy := &closeTrackedProxy{Proxy: namedProxy("active")}
	activeProvider := &closeTrackedProvider{proxies: []constant.Proxy{activeProxy}}
	prior := &config.Config{}
	withCurrentConfig(t, prior)
	tunnel.UpdateProxies(map[string]constant.Proxy{"active": activeProxy}, map[string]cp.ProxyProvider{"active": activeProvider})
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	candidateProxy := &closeTrackedProxy{Proxy: namedProxy("candidate")}
	providerProxy := &closeTrackedProxy{Proxy: namedProxy("provider-only")}
	candidateProvider := &closeTrackedProvider{proxies: []constant.Proxy{candidateProxy, providerProxy, activeProxy}}
	apply := applyHubConfig
	t.Cleanup(func() { applyHubConfig = apply })
	rejected := errors.New("candidate rejected")
	applyHubConfig = func(cfg *config.Config) error {
		if currentConfig != prior {
			t.Error("candidate published before hub accepted it")
		}
		cfg.Proxies["candidate"] = candidateProxy
		cfg.Proxies["alias"] = candidateProxy
		cfg.Proxies["active-alias"] = activeProxy
		cfg.Providers["candidate"] = candidateProvider
		cfg.Providers["alias"] = candidateProvider
		cfg.Providers["active-alias"] = activeProvider
		return rejected
	}
	if err := applyConfig(defaultSetupParams()); !errors.Is(err, rejected) {
		t.Errorf("applyConfig = %v, want original hub error", err)
	}
	if candidateProxy.closes != 1 || providerProxy.closes != 1 || candidateProvider.closes != 1 {
		t.Errorf("candidate closes = proxy:%d provider-only:%d provider:%d, want one each", candidateProxy.closes, providerProxy.closes, candidateProvider.closes)
	}
	if activeProxy.closes != 0 || activeProvider.closes != 0 {
		t.Errorf("closed active resources: proxy:%d provider:%d", activeProxy.closes, activeProvider.closes)
	}
}

func TestApplyConfigParseFallbackAndCommit(t *testing.T) {
	for _, tc := range []struct {
		name           string
		profile        string
		reject         bool
		wantParseError bool
	}{
		{name: "valid", profile: "allow-lan: true\n"},
		{name: "empty"},
		{name: "malformed", profile: "proxies: [unterminated\n", wantParseError: true},
		{name: "rejected fallback", profile: "proxies: [unterminated\n", reject: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := constant.Path.HomeDir()
			constant.SetHomeDir(t.TempDir())
			t.Cleanup(func() { constant.SetHomeDir(home) })
			if err := os.WriteFile(filepath.Join(constant.Path.HomeDir(), "config.yaml"), []byte(tc.profile), 0o600); err != nil {
				t.Fatal(err)
			}
			prior := &config.Config{}
			withCurrentConfig(t, prior)
			apply := applyHubConfig
			wasRunning := isRunning.Swap(false)
			register, stop := registerGeoUpdater, stopGeoUpdater
			registerGeoUpdater, stopGeoUpdater = func() {}, func() {}
			t.Cleanup(func() {
				applyHubConfig = apply
				isRunning.Store(wasRunning)
				registerGeoUpdater, stopGeoUpdater = register, stop
			})
			var candidate *config.Config
			rejected := errors.New("fallback rejected")
			applyHubConfig = func(cfg *config.Config) error {
				candidate = cfg
				if currentConfig != prior {
					t.Error("currentConfig changed before hub success")
				}
				if tc.reject {
					return rejected
				}
				return nil
			}
			err := applyConfig(defaultSetupParams())
			if candidate == nil || candidate.General == nil {
				t.Fatal("parsed/default config did not reach the hub")
			}
			if tc.reject {
				if !errors.Is(err, rejected) || currentConfig != prior {
					t.Fatalf("rejected fallback = %v, prior retained = %v", err, currentConfig == prior)
				}
				return
			}
			if tc.wantParseError {
				if err == nil || !strings.Contains(err.Error(), "yaml") {
					t.Errorf("fallback result = %v, want original YAML error", err)
				}
			} else if err != nil {
				t.Errorf("applyConfig = %v", err)
			}
			if currentConfig != candidate {
				t.Error("hub success did not publish candidate")
			}
			currentConfig = prior
			closeRejectedConfig(candidate)
		})
	}
}

func TestApplyConfigRejectsFailedProviderWithoutChangingActiveState(t *testing.T) {
	if !features.WithLowMemory {
		t.Skip("local-only provider admission requires with_low_memory")
	}
	home := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(home) })
	if err := os.WriteFile(filepath.Join(constant.Path.HomeDir(), "config.yaml"), []byte(`allow-lan: false
rule-providers:
  missing:
    type: file
    behavior: domain
    path: ./missing.yaml
rules:
  - RULE-SET,missing,DIRECT
`), 0o600); err != nil {
		t.Fatal(err)
	}

	prior := &config.Config{General: &config.General{Inbound: config.Inbound{AllowLan: true}}}
	withCurrentConfig(t, prior)
	group := selectorGroup(t, "kept", "first", "second")
	tunnel.UpdateProxies(map[string]constant.Proxy{"kept": group}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	wasRunning := isRunning.Swap(true)
	allowLan := listener.AllowLan()
	listener.SetAllowLan(true)
	t.Cleanup(func() {
		isRunning.Store(wasRunning)
		listener.SetAllowLan(allowLan)
	})
	register, stop := registerGeoUpdater, stopGeoUpdater
	updaterCalls := 0
	registerGeoUpdater = func() { updaterCalls++ }
	stopGeoUpdater = func() { updaterCalls++ }
	t.Cleanup(func() { registerGeoUpdater, stopGeoUpdater = register, stop })

	params := defaultSetupParams()
	params.SelectedMap = map[string]string{"kept": "second"}
	err := applyConfig(params)
	if err == nil || !strings.Contains(err.Error(), "missing") {
		t.Errorf("applyConfig = %v, want missing-provider admission error", err)
	}
	if currentConfig != prior {
		t.Error("rejected config replaced currentConfig")
	}
	if got := groupNow(t, group); got != "first" {
		t.Errorf("active selection = %q, want first", got)
	}
	if !listener.AllowLan() {
		t.Error("rejected config changed active listeners")
	}
	if updaterCalls != 0 {
		t.Errorf("rejected config reconciled geo updater %d times", updaterCalls)
	}
}
