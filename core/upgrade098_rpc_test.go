//go:build !cgo

package main

import (
	"encoding/json"
	"testing"
)

func TestClearDNSCacheActualRPCMethodTarget(t *testing.T) {
	frame := captureSingleFrame(t, func() {
		handleMethodCall(&MethodCall{ID: "clear-dns-098", Method: CoreMethod("clearDnsCache"), Arguments: json.RawMessage("null")}, MethodResponse{ID: "clear-dns-098"})
	})
	var response struct {
		ID     string       `json:"id"`
		Result bool         `json:"result"`
		Error  *MethodError `json:"error"`
	}
	if err := json.Unmarshal(frame, &response); err != nil {
		t.Fatal(err)
	}
	if response.ID != "clear-dns-098" || response.Error != nil || !response.Result {
		t.Fatalf("clear DNS target failed: %s", frame)
	}
}
