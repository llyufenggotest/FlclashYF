package main

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

type dnsWrapperService struct{}

func (dnsWrapperService) ServeMsg(_ context.Context, q *D.Msg) (*D.Msg, error) {
	r := new(D.Msg)
	r.SetReply(q)
	r.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.IPv4(192, 0, 2, 8)}}
	return r, nil
}
func dnsWrapperAddress(t *testing.T) string {
	t.Helper()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	a := l.Addr().String()
	l.Close()
	return a
}
func dnsWrapperFree(t *testing.T, a string) {
	t.Helper()
	tcp, e := net.Listen("tcp", a)
	if e != nil {
		t.Fatal(e)
	}
	defer tcp.Close()
	udp, e := net.ListenPacket("udp", a)
	if e != nil {
		t.Fatal(e)
	}
	defer udp.Close()
}
func dnsWrapperQuery(t *testing.T, a string) {
	t.Helper()
	for _, n := range []string{"tcp", "udp"} {
		q := new(D.Msg)
		q.SetQuestion("private.test.", D.TypeA)
		r, _, e := (&D.Client{Net: n, Timeout: time.Second}).Exchange(q, a)
		if e != nil {
			t.Fatal(e)
		}
		if len(r.Answer) != 1 {
			t.Fatal("lost private response")
		}
	}
}
func TestDNSWrapperReleaseShutdown(t *testing.T) {
	for _, tc := range []struct {
		name string
		stop func() bool
	}{{"release", handleReleaseConfig}, {"shutdown", handleShutdown}} {
		t.Run(tc.name, func(t *testing.T) {
			dns.StopServer()
			if !handleResumeDnsListener() {
				t.Fatal("resume failed")
			}
			defer dns.StopServer()
			addr := dnsWrapperAddress(t)
			if e := dns.ReCreateServerWithError(addr, &net.ListenConfig{}, dnsWrapperService{}); e != nil {
				t.Fatal(e)
			}
			dnsWrapperQuery(t, addr)
			isInit.Store(true)
			if !tc.stop() {
				t.Fatal("stop failed")
			}
			dnsWrapperFree(t, addr)
			if tc.name == "release" && !isInit.Load() {
				t.Fatal("release changed init contract")
			}
			if tc.name == "shutdown" && isInit.Load() {
				t.Fatal("shutdown did not clear init")
			}
			if !handleResumeDnsListener() {
				t.Fatal("empty desired listener failed")
			}
			dnsWrapperFree(t, addr)
		})
	}
}
func TestDNSWrapperOwnershipAndFailedResume(t *testing.T) {
	dns.StopServer()
	_ = handleResumeDnsListener()
	defer func() { dns.StopServer(); _ = handleResumeDnsListener() }()
	addr := dnsWrapperAddress(t)
	previous := resolver.DefaultService
	svc := dnsWrapperService{}
	resolver.DefaultService = svc
	defer func() { resolver.DefaultService = previous }()
	if e := dns.ReCreateServerWithError(addr, &net.ListenConfig{}, svc); e != nil {
		t.Fatal(e)
	}
	if !handleSuspendDnsListener() {
		t.Fatal("suspend failed")
	}
	dnsWrapperFree(t, addr)
	if resolver.DefaultService != svc {
		t.Fatal("suspend changed internal resolver")
	}
	// A setup in this process must preserve the suspended state.
	dns.ReCreateServer(addr, &net.ListenConfig{}, svc)
	dnsWrapperFree(t, addr)
	tcp, e := net.Listen("tcp", addr)
	if e != nil {
		t.Fatal(e)
	}
	if handleResumeDnsListener() {
		tcp.Close()
		t.Fatal("busy resume reported success")
	}
	tcp.Close()
	if !handleResumeDnsListener() {
		t.Fatal("same-address resume failed")
	}
	dnsWrapperQuery(t, addr)
	if !handleSuspendDnsListener() {
		t.Fatal("suspend failed")
	}
	handleReleaseConfig()
	dns.ReCreateServer(addr, &net.ListenConfig{}, svc)
	dnsWrapperFree(t, addr)
	if !handleResumeDnsListener() {
		t.Fatal("release erased owner gate or desired config")
	}
	dnsWrapperQuery(t, addr)
}
func TestDNSWrapperSetupReportsReadinessFailure(t *testing.T) {
	dns.StopServer()
	_ = handleResumeDnsListener()
	defer dns.StopServer()
	oldSetup := setupConfig
	oldInit := isInit.Load()
	defer func() { setupConfig = oldSetup; isInit.Store(oldInit) }()
	isInit.Store(true)
	addr := dnsWrapperAddress(t)
	tcp, e := net.Listen("tcp", addr)
	if e != nil {
		t.Fatal(e)
	}
	setupConfig = func(*SetupParams) error {
		return dns.ReplaceServerWithError(addr, &net.ListenConfig{}, dnsWrapperService{})
	}
	if got := handleSetupConfig(&SetupParams{}); got == "" {
		tcp.Close()
		t.Fatal("setup acknowledged failed bind")
	}
	tcp.Close()
	if got := handleSetupConfig(&SetupParams{}); got != "" {
		t.Fatal(got)
	}
	dnsWrapperQuery(t, addr)
}
