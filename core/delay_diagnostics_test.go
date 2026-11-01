package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// This fixture crosses the real wrapper and adapter parser, before any dial.
// Diagnostics must be in corelog, not new fields in the Delay wire contract.
func TestDelayDiagnosticsProductionInvalidSchemeBatch(t *testing.T) {
	waitDelayDiagnosticIdle(t)
	const name = "BAIT-NODE-SECRET"
	const target = "bait-scheme://BAIT-USER:BAIT-PASSWORD@BAIT-HOST.invalid/BAIT-PATH?secret=BAIT-QUERY"
	old := tunnel.AllProxies()
	p := adapter.NewProxy(outbound.NewDirectWithOption(outbound.DirectOption{Name: name}))
	tunnel.UpdateProxies(map[string]C.Proxy{name: p}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(old, nil) })
	if _, err := p.URLTest(context.Background(), target, nil); err == nil {
		t.Fatal("fixture must fail inside real adapter before network")
	}
	sub := log.Subscribe()
	defer log.UnSubscribe(sub)
	for i := 0; i < 51; i++ {
		d := handleTestDelay(&TestDelayParams{ProxyName: name, TestUrl: target, Timeout: 100})
		if d == nil || d.Value != -1 || d.Name != name || d.Url != target {
			t.Fatal("Delay semantics changed")
		}
		b, err := json.Marshal(d)
		if err != nil {
			t.Fatal(err)
		}
		var wire map[string]any
		if err = json.Unmarshal(b, &wire); err != nil {
			t.Fatal(err)
		}
		if len(wire) != 3 || wire["name"] != name || wire["url"] != target || wire["value"] != float64(-1) {
			t.Fatalf("Delay wire changed: %s", b)
		}
	}
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	for {
		select {
		case event := <-sub:
			const prefix = "delay_test_summary "
			if !strings.HasPrefix(event.Payload, prefix) {
				continue
			}
			if strings.Contains(event.Payload, "BAIT-") || strings.Contains(event.Payload, "scheme not Support") {
				t.Fatalf("private input/raw error leaked: %s", event.Payload)
			}
			var summary struct {
				Completed uint64 `json:"completed"`
				Negative  uint64 `json:"negative"`
				Coalesced uint64 `json:"coalesced"`
				Invalid   uint64 `json:"scheme_invalid"`
				Host      uint64 `json:"host_present"`
				Proxy     uint64 `json:"proxy_present"`
				Buckets   []struct {
					Class, Stage, Cause string
					Count               uint64
				} `json:"buckets"`
			}
			if err := json.Unmarshal([]byte(strings.TrimPrefix(event.Payload, prefix)), &summary); err != nil {
				t.Fatal(err)
			}
			if summary.Completed != 51 || summary.Negative != 51 || summary.Coalesced != 50 || summary.Invalid != 51 || summary.Host != 51 || summary.Proxy != 51 {
				t.Fatalf("lost batch counts: %+v", summary)
			}
			// The adapter's unsupported-scheme error is untyped. URL structure is
			// evidence about input, NOT proof of which execution stage failed.
			if len(summary.Buckets) != 1 || summary.Buckets[0].Class != "unknown" || summary.Buckets[0].Stage != "unknown" || summary.Buckets[0].Cause != "untyped" || summary.Buckets[0].Count != 51 {
				t.Fatalf("invented failure stage or lost errors: %+v", summary.Buckets)
			}
			t.Log(event.Payload)
			return
		case <-timer.C:
			t.Fatal("RED: real handleTestDelay discarded adapter errors; no privacy-safe bounded 51-result corelog summary")
		}
	}
}
