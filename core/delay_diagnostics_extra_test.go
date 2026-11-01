package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

type delayPoisonError struct{}

func (delayPoisonError) Error() string { panic("diagnostics called Error()") }

func TestDelayDiagnosticsTypedPrivacy(t *testing.T) {
	const bait = "BAIT-SECRET-HOST-URL-PASSWORD"
	cases := []struct {
		name string
		err  error
		want delayFailure
	}{
		{"unknown", errors.New(bait), delayUnknown},
		{"no_error_string", delayPoisonError{}, delayUnknown},
		{"cancel", fmt.Errorf("%s: %w", bait, context.Canceled), delayCanceled},
		{"deadline", context.DeadlineExceeded, delayDeadline},
		{"dns", &net.DNSError{Err: bait, Name: bait, Server: bait}, delayDNS},
		{"dns_timeout", &net.DNSError{Err: bait, Name: bait, IsTimeout: true}, delayDNSTimeout},
		{"dns_missing", &net.DNSError{Err: bait, Name: bait, IsNotFound: true}, delayDNSNotFound},
		{"authority", &url.Error{Op: bait, URL: bait, Err: x509.UnknownAuthorityError{}}, delayCertAuthority},
		{"hostname", x509.HostnameError{Host: bait}, delayCertHostname},
		{"invalid", x509.CertificateInvalidError{Detail: bait}, delayCertInvalid},
		{"tls_record", tls.RecordHeaderError{Msg: bait}, delayTLSRecord},
		{"tls_alert", tls.AlertError(42), delayTLSAlert},
		{"refused", &net.OpError{Op: bait, Net: "udp", Err: syscall.ECONNREFUSED}, delayRefused},
		{"reset", syscall.ECONNRESET, delayReset},
		{"syscall", syscall.EINVAL, delaySyscall},
		{"net_op_not_tcp_or_tls", &net.OpError{Op: "handshake", Net: "tcp", Err: delayPoisonError{}}, delayNetOp},
		{"url_parse", &url.Error{Op: "parse", URL: bait, Err: url.EscapeError(bait)}, delayURLParse},
		{"url_wrapper_not_tls", &url.Error{Op: "tls", URL: bait, Err: errors.New(bait)}, delayURLWrapper},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyDelayFailure(tc.err)
			if got != tc.want {
				t.Fatalf("classification=%v want=%v", got, tc.want)
			}
			b, err := json.Marshal(delayFailureLabels[got])
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(b), bait) {
				t.Fatal("private cause leaked")
			}
		})
	}
	for _, tc := range []struct {
		raw   string
		shape delayURLShape
		host  bool
	}{
		{"http://user:password@bait.invalid/path?token=secret", delayURLHTTP, true},
		{"https://bait.invalid/", delayURLHTTPS, true},
		{"bait://bait.invalid/", delayURLInvalid, true},
		{"http:///no-host", delayURLInvalid, false},
		{"://%BAIT", delayURLInvalid, false},
	} {
		shape, host := delayTestURLShape(tc.raw)
		if shape != tc.shape || host != tc.host {
			t.Fatal("URL shape mismatch")
		}
	}
}

func TestDelayDiagnosticsBoundedStorm(t *testing.T) {
	// Simulate an already publishing (possibly stalled) log sink. Completion
	// must keep a fixed batch, not allocate one timer/goroutine per request.
	b := &delayDiagnosticBatch{active: true}
	const workers = 20
	const perWorker = 1000
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < perWorker; j++ {
				b.add(delayRefused, -1, false, delayURLHTTPS, true, true)
			}
		}()
	}
	wg.Wait()
	b.mu.Lock()
	if b.timer != nil {
		t.Fatal("storm scheduled additional timer while publication active")
	}
	s := b.snapshotLocked()
	b.mu.Unlock()
	if s.Completed != workers*perWorker || s.Negative != workers*perWorker || s.Coalesced != workers*perWorker-1 || len(s.Buckets) != 1 || s.Buckets[0].Count != workers*perWorker {
		t.Fatalf("storm lost counts: %+v", s)
	}
	payload, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	if len(payload) > 1024 {
		t.Fatalf("unbounded summary bytes=%d", len(payload))
	}
	oneBucketBytes := len(payload)
	b.summary.Completed = delayDiagnosticCountCap
	b.counts[delayUnknown] = delayDiagnosticCountCap
	b.add(delayUnknown, -1, false, delayURLInvalid, false, false)
	if !b.summary.Saturated || b.summary.Completed != delayDiagnosticCountCap || b.counts[delayUnknown] != delayDiagnosticCountCap {
		t.Fatal("counter cap wrapped or not disclosed")
	}
	// Every label at once remains bounded, independent of inputs and node count.
	for i := range b.counts {
		b.counts[i] = delayDiagnosticCountCap
	}
	b.mu.Lock()
	all := b.snapshotLocked()
	b.mu.Unlock()
	payload, err = json.Marshal(all)
	if err != nil {
		t.Fatal(err)
	}
	if len(payload) > 4096 {
		t.Fatalf("fixed vocabulary output grew: %d", len(payload))
	}
	t.Logf("storm=%d records, single-bucket=%d bytes, all-buckets=%d bytes", workers*perWorker, oneBucketBytes, len(payload))
}

func TestDelayDiagnosticsTimerAndAllocations(t *testing.T) {
	b := &delayDiagnosticBatch{}
	b.add(delayOK, 1, false, delayURLHTTP, true, true)
	b.mu.Lock()
	first := b.timer
	b.mu.Unlock()
	for i := 0; i < 100; i++ {
		b.add(delayUnknown, -1, false, delayURLInvalid, false, true)
	}
	b.mu.Lock()
	if first == nil || b.timer != first {
		t.Fatal("one burst must reuse one coalesced timer")
	}
	if !first.Stop() {
		t.Fatal("fixture did not stop timer before publication")
	}
	b.timer = nil
	b.active = true
	b.mu.Unlock()
	allocs := testing.AllocsPerRun(1000, func() {
		b.add(delayOK, 1, false, delayURLHTTPS, true, true)
	})
	if allocs != 0 {
		t.Fatalf("success accounting allocated per result: %f", allocs)
	}
	t.Logf("success accounting allocations/run=%f", allocs)
}

func TestDelayDiagnosticsExportedCorelog(t *testing.T) {
	waitDelayDiagnosticIdle(t)
	handleStopLogNotify()
	ensureLogStarted()
	old := tunnel.AllProxies()
	tunnel.UpdateProxies(nil, nil)
	defer tunnel.UpdateProxies(old, nil)
	d := handleTestDelay(&TestDelayParams{ProxyName: "BAIT-EXPORT-NODE", TestUrl: "https://BAIT-EXPORT-HOST.invalid/BAIT-EXPORT-PASSWORD"})
	if d == nil || d.Value != -1 {
		t.Fatal("missing-proxy result changed")
	}
	until := time.Now().Add(3 * time.Second)
	for time.Now().Before(until) {
		logNotifyMu.Lock()
		var found string
		for i := 0; i < logNotifyLen; i++ {
			e := logNotifyCache[(logNotifyStart+i)%maxCachedLogNotify]
			if strings.HasPrefix(e.Payload, "delay_test_summary ") {
				var s delaySummary
				if json.Unmarshal([]byte(strings.TrimPrefix(e.Payload, "delay_test_summary ")), &s) == nil && s.Completed == 1 && s.ProxyPresent == 0 && s.Negative == 1 {
					found = e.Payload
				}
			}
		}
		logNotifyMu.Unlock()
		if found != "" {
			if strings.Contains(found, "BAIT-") {
				t.Fatal("corelog export leaked private inputs")
			}
			t.Log("privacy-safe summary reached existing stamped corelog export cache")
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("summary did not reach existing corelog export channel")
}

func waitDelayDiagnosticIdle(t *testing.T) {
	t.Helper()
	until := time.Now().Add(3 * time.Second)
	for time.Now().Before(until) {
		delayDiagnostics.mu.Lock()
		idle := !delayDiagnostics.active
		delayDiagnostics.mu.Unlock()
		if idle {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("diagnostic worker failed to become idle")
}

func TestDelayDiagnosticsProductionOutcomes(t *testing.T) {
	waitDelayDiagnosticIdle(t)
	const name = "BAIT-PROXY-SECRET"
	p := adapter.NewProxy(outbound.NewDirectWithOption(outbound.DirectOption{Name: name}))
	old := tunnel.AllProxies()
	tunnel.UpdateProxies(map[string]C.Proxy{name: p}, nil)
	defer tunnel.UpdateProxies(old, nil)
	sub := log.Subscribe()
	defer log.UnSubscribe(sub)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(8 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	d := handleTestDelay(&TestDelayParams{ProxyName: name, TestUrl: server.URL, Timeout: 500})
	if d == nil || d.Value <= 0 {
		t.Fatal("real adapter loopback success lost")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	refusedURL := "http://" + listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	d = handleTestDelay(&TestDelayParams{ProxyName: name, TestUrl: refusedURL, Timeout: 500})
	if d == nil || d.Value != -1 {
		t.Fatal("real refused connection result changed")
	}
	addr := blackHoleServer(t)
	d = handleTestDelay(&TestDelayParams{ProxyName: name, TestUrl: "http://" + addr.String(), Timeout: 30})
	if d == nil || d.Value != -1 {
		t.Fatal("real adapter deadline changed")
	}
	for i := 0; i < 51; i++ {
		d = handleTestDelay(&TestDelayParams{ProxyName: "BAIT-MISSING-SECRET", TestUrl: "https://BAIT-HOST.invalid/private"})
		if d == nil || d.Value != -1 {
			t.Fatal("missing-proxy result changed")
		}
	}
	for i := 0; i < delayTestConcurrency; i++ {
		delayTestSlots <- struct{}{}
	}
	d = handleTestDelay(&TestDelayParams{ProxyName: name, TestUrl: server.URL, Timeout: 10})
	for i := 0; i < delayTestConcurrency; i++ {
		<-delayTestSlots
	}
	if d != nil {
		t.Fatal("wrapper admission timeout must still return nil")
	}
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	for {
		select {
		case e := <-sub:
			if strings.Contains(e.Payload, "BAIT-") {
				t.Fatalf("input leaked: %s", e.Payload)
			}
			if !strings.HasPrefix(e.Payload, "delay_test_summary ") {
				continue
			}
			var s delaySummary
			if err := json.Unmarshal([]byte(strings.TrimPrefix(e.Payload, "delay_test_summary ")), &s); err != nil {
				t.Fatal(err)
			}
			if s.Completed != 55 || s.Positive != 1 || s.Negative != 53 || s.Null != 1 || s.ProxyPresent != 4 || s.SchemeHTTP != 4 || s.SchemeHTTPS != 51 {
				t.Fatalf("lost outcomes: %+v", s)
			}
			counts := map[string]uint64{}
			for _, bucket := range s.Buckets {
				counts[bucket.Class] = bucket.Count
			}
			if counts["missing_proxy"] != 51 || counts["success"] != 1 || counts["deadline"] != 1 || counts["queue_deadline"] != 1 || counts["connection_refused"]+counts["syscall"] != 1 {
				t.Fatalf("lost typed/rejection classes: %+v", counts)
			}
			t.Log(e.Payload)
			return
		case <-timer.C:
			t.Fatal("no real producer summary")
		}
	}
}
