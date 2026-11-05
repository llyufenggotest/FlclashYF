//go:build !cgo

package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
)

// DNS replies and event batches share conn. Ignore only recognized event
// envelopes, and still require exactly one successful target response.
func dnsRPCResponseFrame(frames [][]byte, id string) ([]byte, error) {
	var response []byte
	count := 0
	for _, frame := range frames {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(frame, &fields); err != nil || fields == nil {
			return nil, fmt.Errorf("malformed IPC frame: %s", frame)
		}
		if rawID, ok := fields["id"]; ok {
			var gotID string
			var decoded struct {
				Result bool         `json:"result"`
				Error  *MethodError `json:"error"`
			}
			if err := json.Unmarshal(rawID, &gotID); err != nil || gotID != id {
				return nil, fmt.Errorf("unexpected RPC id: %s", frame)
			}
			if _, ok := fields["result"]; !ok || fields["method"] != nil || fields["arguments"] != nil || fields["type"] != nil {
				return nil, fmt.Errorf("malformed target response: %s", frame)
			}
			if err := json.Unmarshal(frame, &decoded); err != nil || !decoded.Result || decoded.Error != nil {
				return nil, fmt.Errorf("unsuccessful target response: %s", frame)
			}
			count++
			response = frame
			continue
		}
		var event messageBatchCall
		if err := json.Unmarshal(frame, &event); err != nil || event.Method != messageMethod || len(event.Arguments) == 0 || len(fields) != 2 {
			return nil, fmt.Errorf("unexpected non-response frame: %s", frame)
		}
		for _, message := range event.Arguments {
			switch message.Type {
			case LogMessage, DelayMessage, RequestMessage, DnsMessage, LoadedMessage, GeoUpdateMessage:
			default:
				return nil, fmt.Errorf("unknown event type: %s", frame)
			}
		}
	}
	if count != 1 {
		return nil, fmt.Errorf("captured %d target RPC responses for %q, want 1", count, id)
	}
	return response, nil
}

func captureDNSRPCResponse(t *testing.T, id string, run func()) []byte {
	t.Helper()
	frame, err := dnsRPCResponseFrame(captureFrames(t, run), id)
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

// Reproduce a delayed real logger -> message batcher delivery inside the RPC
// capture window; no sleep-based assumption about when the event is flushed.
func TestDNSWrapperRPCWithAsyncLog(t *testing.T) {
	dns.StopServer()
	defer func() { dns.StopServer(); _ = handleResumeDnsListener() }()
	logNotifyMu.Lock()
	previousNotify := logNotifyEnabled
	logNotifyMu.Unlock()
	oldLevel := log.Level()
	log.SetLevel(log.INFO)
	defer log.SetLevel(oldLevel)
	handleStartLogNotify()
	defer func() {
		logNotifyMu.Lock()
		logNotifyEnabled = previousNotify
		logNotifyMu.Unlock()
	}()
	frame := captureDNSRPCResponse(t, "dns-async", func() {
		connMu.Lock()
		fake := conn.(*fakeConn)
		connMu.Unlock()
		log.Infoln("dns-rpc-fixture async log counterexample")
		deadline := time.Now().Add(time.Second)
		for {
			found := false
			for _, event := range fake.frames(t) {
				if strings.Contains(string(event), "dns-rpc-fixture async log counterexample") {
					found = true
					break
				}
			}
			if found {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("logger/batcher did not deliver counterexample event")
			}
			time.Sleep(time.Millisecond)
		}
		handleMethodCall(&MethodCall{ID: "dns-async", Method: suspendDnsListenerMethod, Arguments: json.RawMessage("null")}, MethodResponse{ID: "dns-async"})
	})
	var response MethodResponse
	if err := json.Unmarshal(frame, &response); err != nil || response.Error != nil || response.Result != true {
		t.Fatalf("null-argument RPC failed: %s (%v)", frame, err)
	}
}

func TestDNSRPCResponseFrameValidation(t *testing.T) {
	reply := []byte(`{"id":"dns-owner","result":true}`)
	event := []byte(`{"method":"message","arguments":[{"type":"log","data":{"Payload":"late DNS startup"}}]}`)
	for _, tc := range []struct {
		name   string
		frames [][]byte
		valid  bool
	}{
		{"single", [][]byte{reply}, true},
		{"event-before", [][]byte{event, reply}, true},
		{"event-after", [][]byte{reply, event}, true},
		{"missing", [][]byte{event}, false},
		{"duplicate", [][]byte{reply, event, reply}, false},
		{"wrong-id", [][]byte{[]byte(`{"id":"other","result":true}`)}, false},
		{"malformed-json", [][]byte{reply, []byte(`{`)}, false},
		{"missing-result", [][]byte{[]byte(`{"id":"dns-owner"}`)}, false},
		{"null-result", [][]byte{[]byte(`{"id":"dns-owner","result":null}`)}, false},
		{"wrong-result-type", [][]byte{[]byte(`{"id":"dns-owner","result":"true"}`)}, false},
		{"failed-result", [][]byte{[]byte(`{"id":"dns-owner","result":false}`)}, false},
		{"error", [][]byte{[]byte(`{"id":"dns-owner","result":true,"error":{"code":"failed"}}`)}, false},
		{"target-as-event", [][]byte{reply, []byte(`{"id":"dns-owner","method":"message","arguments":[{"type":"log"}]}`)}, false},
		{"unidentified-result", [][]byte{reply, []byte(`{"result":true}`)}, false},
		{"unknown-method", [][]byte{reply, []byte(`{"method":"other","arguments":[{"type":"log"}]}`)}, false},
		{"unknown-event-type", [][]byte{reply, []byte(`{"method":"message","arguments":[{"type":"other"}]}`)}, false},
		{"malformed-event", [][]byte{reply, []byte(`{"method":"message","arguments":"bad"}`)}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := dnsRPCResponseFrame(tc.frames, "dns-owner")
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v, frame=%s, err=%v", tc.valid, got, err)
			}
		})
	}
}

func TestDNSWrapperRPCNullArguments(t *testing.T) {
	dns.StopServer()
	defer func() { dns.StopServer(); _ = handleResumeDnsListener() }()
	for _, m := range []CoreMethod{suspendDnsListenerMethod, resumeDnsListenerMethod} {
		id := "dns-owner-" + string(m)
		frame := captureDNSRPCResponse(t, id, func() {
			handleMethodCall(&MethodCall{ID: id, Method: m, Arguments: json.RawMessage("null")}, MethodResponse{ID: id})
		})
		var response struct {
			Result bool         `json:"result"`
			Error  *MethodError `json:"error"`
		}
		if e := json.Unmarshal(frame, &response); e != nil {
			t.Fatal(e)
		}
		if response.Error != nil || !response.Result {
			t.Fatalf("%s: %s", m, frame)
		}
	}
}
