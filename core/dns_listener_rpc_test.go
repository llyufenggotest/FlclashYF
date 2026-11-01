//go:build !cgo

package main

import (
	"encoding/json"
	"github.com/metacubex/mihomo/dns"
	"testing"
)

func TestDNSWrapperRPCNullArguments(t *testing.T) {
	dns.StopServer()
	defer func() { dns.StopServer(); _ = handleResumeDnsListener() }()
	for _, m := range []CoreMethod{suspendDnsListenerMethod, resumeDnsListenerMethod} {
		frame := captureSingleFrame(t, func() {
			handleMethodCall(&MethodCall{ID: "dns-owner", Method: m, Arguments: json.RawMessage("null")}, MethodResponse{ID: "dns-owner"})
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
