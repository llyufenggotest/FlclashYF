package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
	D "github.com/miekg/dns"
)

// Use the real wrapper/hub transaction: no setupConfig or applyHubConfig stub.
func TestDNSWrapperSetupRejectsCandidateBeforeCommit(t *testing.T) {
	home := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	defer constant.SetHomeDir(home)
	dns.StopServer()
	if !handleResumeDnsListener() {
		t.Fatal("initial resume")
	}
	oldInit, oldRunning := isInit.Swap(true), isRunning.Swap(false)
	defer func() {
		handleReleaseConfig()
		dns.StopServer()
		_ = handleResumeDnsListener()
		isInit.Store(oldInit)
		isRunning.Store(oldRunning)
		if c := cachefile.Cache(); c.DB != nil {
			_ = c.Close()
		}
	}()
	writeProfile := func(addr string, marker bool) {
		t.Helper()
		profile := fmt.Sprintf("mode: direct\nlog-level: silent\nallow-lan: %t\ngeo-auto-update: false\nhosts:\n  private.test: 192.0.2.8\ndns:\n  enable: true\n  listen: %s\n  enhanced-mode: normal\n  use-hosts: true\n  nameserver: [127.0.0.1:9]\nrules: [\"MATCH,DIRECT\"]\n", marker, addr)
		if err := os.WriteFile(filepath.Join(constant.Path.HomeDir(), "config.yaml"), []byte(profile), 0600); err != nil {
			t.Fatal(err)
		}
	}
	addrA := dnsWrapperAddress(t)
	writeProfile(addrA, false)
	if got := handleSetupConfig(defaultSetupParams()); got != "" {
		t.Fatal(got)
	}
	prior, service, r, mapper, hosts := currentConfig, resolver.DefaultService, resolver.DefaultResolver, resolver.DefaultHostMapper, resolver.DefaultHosts
	oldProxy := tunnel.AllProxies()["DIRECT"]
	dnsWrapperQuery(t, addrA)
	addrB := dnsWrapperAddress(t)
	blocker, err := net.Listen("tcp", addrB)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	writeProfile(addrB, true)
	got := handleSetupConfig(defaultSetupParams())
	if !strings.Contains(got, "DNS TCP bind:") {
		t.Fatalf("setup error = %q", got)
	}
	if currentConfig != prior || currentConfig.General.AllowLan {
		t.Error("rejected raw/current config published")
	}
	if resolver.DefaultService != service || resolver.DefaultResolver != r || resolver.DefaultHostMapper != mapper || resolver.DefaultHosts != hosts {
		t.Error("rejected resolver globals published")
	}
	if tunnel.AllProxies()["DIRECT"] != oldProxy {
		t.Error("rejected proxy runtime published")
	}
	dnsWrapperQuery(t, addrA)
	// Partial UDP bind must be closed, without freeing the active old listener.
	udp, err := net.ListenPacket("udp", addrB)
	if err != nil {
		t.Fatal("candidate UDP leaked:", err)
	}
	udp.Close()
	blocker.Close()
	if !handleResumeDnsListener() {
		t.Fatal("late resume failed")
	}
	dnsWrapperQuery(t, addrA)
	dnsWrapperFree(t, addrB)
	// Same-address admission must reuse the active generation, not self-conflict.
	writeProfile(addrA, true)
	if got := handleSetupConfig(defaultSetupParams()); got != "" {
		t.Fatal("same-address replacement:", got)
	}
	if currentConfig == prior || !currentConfig.General.AllowLan || resolver.DefaultService == service {
		t.Fatal("same-address replacement did not commit")
	}
	dnsWrapperQuery(t, addrA)
	// A successful changed-address transaction really activates the new service.
	writeProfile(addrB, false)
	if got := handleSetupConfig(defaultSetupParams()); got != "" {
		t.Fatal("new-address replacement:", got)
	}
	dnsWrapperQuery(t, addrB)
	dnsWrapperFree(t, addrA)
}

func TestDNSWrapperSetupSuspendedTransaction(t *testing.T) {
	home := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	defer constant.SetHomeDir(home)
	dns.StopServer()
	if !handleSuspendDnsListener() {
		t.Fatal("suspend")
	}
	oldInit := isInit.Swap(true)
	defer func() {
		handleReleaseConfig()
		dns.StopServer()
		_ = handleResumeDnsListener()
		isInit.Store(oldInit)
		if c := cachefile.Cache(); c.DB != nil {
			_ = c.Close()
		}
	}()
	addr := dnsWrapperAddress(t)
	blocker, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	profile := fmt.Sprintf("mode: direct\nlog-level: silent\ngeo-auto-update: false\nhosts:\n  private.test: 192.0.2.8\ndns:\n  enable: true\n  use-hosts: true\n  listen: %s\n  nameserver: [127.0.0.1:9]\n", addr)
	if err := os.WriteFile(filepath.Join(constant.Path.HomeDir(), "config.yaml"), []byte(profile), 0600); err != nil {
		t.Fatal(err)
	}
	if got := handleSetupConfig(defaultSetupParams()); got != "" {
		t.Fatal("suspended setup:", got)
	}
	if handleResumeDnsListener() {
		t.Fatal("busy resume acknowledged")
	}
	blocker.Close()
	if !handleResumeDnsListener() {
		t.Fatal("resume retry")
	}
	dnsWrapperQuery(t, addr)
	// Explicit local exchange makes this fixture exercise the production service.
	q := new(D.Msg)
	q.SetQuestion("private.test.", D.TypeA)
	if _, _, err := (&D.Client{Net: "tcp", Timeout: time.Second}).Exchange(q, addr); err != nil {
		t.Fatal(err)
	}
}
