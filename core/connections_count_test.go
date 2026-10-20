//go:build !cgo

package main

import (
	"encoding/json"
	"fmt"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"testing"
)

func TestConnectionsCountMethodTracksJoinLeaveAndClose(t *testing.T) {
	setupNodeTraffic(t)
	read := func(want int) {
		t.Helper()
		frame := captureSingleFrame(t, func() {
			handleMethodCall(&MethodCall{ID: "count", Method: CoreMethod("getConnectionsCount")}, MethodResponse{ID: "count"})
		})
		var response struct {
			Result int          `json:"result"`
			Error  *MethodError `json:"error"`
		}
		if err := json.Unmarshal(frame, &response); err != nil {
			t.Fatal(err)
		}
		if response.Error != nil || response.Result != want {
			t.Fatalf("count response = %s; want scalar integer %d", frame, want)
		}
	}
	read(0)
	node := trafficNode("count-test", "")
	tcp := trafficTCP(t, node, 0, 0)
	udp := trafficUDP(node, 0, 0)
	read(2)
	if len(handleGetConnections().Connections) != 2 {
		t.Fatal("full snapshot lost connections")
	}
	tcp.Close()
	read(1)
	handleCloseConnections()
	read(0)
	udp.Close()
	read(0)
	if len(handleGetConnections().Connections) != 0 {
		t.Fatal("closed trackers retained")
	}
}

// The count path must not inspect or allocate TrackerInfo models.
func BenchmarkConnectionsRead(b *testing.B) {
	previous := statistic.DefaultManager
	statistic.DefaultManager = &statistic.Manager{}
	defer func() { statistic.DefaultManager = previous }()
	for i := 0; i < 1000; i++ {
		statistic.DefaultManager.Join(&benchmarkTracker{id: fmt.Sprint(i)})
	}
	b.Run("count1000", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			handleGetConnectionsCount()
		}
	})
	b.Run("snapshot1000", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			handleGetConnections()
		}
	})
}

type benchmarkTracker struct {
	statistic.Tracker
	id string
}

func (c *benchmarkTracker) ID() string                   { return c.id }
func (c *benchmarkTracker) Info() *statistic.TrackerInfo { return &statistic.TrackerInfo{} }

type countOnlyTracker struct {
	statistic.Tracker
	id string
}

func (c *countOnlyTracker) ID() string                   { return c.id }
func (c *countOnlyTracker) Info() *statistic.TrackerInfo { panic("count RPC called Info") }
func TestConnectionsCountDoesNotBuildSnapshot(t *testing.T) {
	setupNodeTraffic(t)
	for _, id := range []string{"a", "b"} {
		statistic.DefaultManager.Join(&countOnlyTracker{id: id})
	}
	frame := captureSingleFrame(t, func() { handleMethodCall(&MethodCall{Method: CoreMethod("getConnectionsCount")}, MethodResponse{}) })
	var response struct {
		Result int          `json:"result"`
		Error  *MethodError `json:"error"`
	}
	if err := json.Unmarshal(frame, &response); err != nil {
		t.Fatal(err)
	}
	if response.Error != nil || response.Result != 2 {
		t.Fatalf("count-only response: %s", frame)
	}
}
