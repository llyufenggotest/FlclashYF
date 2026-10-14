//go:build windows && !cgo

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Microsoft/go-winio"
)

type readinessIPCConn struct {
	ipcConn
	ready chan struct{}
	once  sync.Once
}

func (c *readinessIPCConn) Read(p []byte) (int, error) {
	// serve installs its connection before entering the production read loop.
	c.once.Do(func() { close(c.ready) })
	return c.ipcConn.Read(p)
}

func TestWindowsNamedPipeRPCDuringLogBurst(t *testing.T) {
	name := fmt.Sprintf(`\\.\pipe\flclashyf-rpc-regression-%d-%d`, os.Getpid(), time.Now().UnixNano())
	listener, err := winio.ListenPipe(name, &winio.PipeConfig{InputBufferSize: 512, OutputBufferSize: 512})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan ipcConn, 1)
	go func() {
		peer, err := listener.Accept()
		if err == nil {
			accepted <- peer
		}
	}()
	deadline := time.Now().Add(10 * time.Second)
	connectTimeout := 10 * time.Second
	core, err := winio.DialPipe(name, &connectTimeout)
	if err != nil {
		t.Fatal(err)
	}
	host := <-accepted
	defer host.Close()
	if err := host.SetWriteDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	// No init/config/TUN: only the production IPC dispatcher is exercised.
	finished := make(chan struct{})
	ready := make(chan struct{})
	readyCore := &readinessIPCConn{ipcConn: core, ready: ready}
	go func() { defer close(finished); serve(readyCore) }()
	defer func() {
		_ = host.Close()
		select {
		case <-finished:
		case <-time.After(2 * time.Second):
			t.Error("serve did not exit after peer close")
		}
	}()
	select {
	case <-ready:
	case <-time.After(10 * time.Second):
		t.Fatal("serve did not publish the IPC connection")
	}
	logNotifyMu.Lock()
	previousNotify := logNotifyEnabled
	logNotifyMu.Unlock()
	defer func() { logNotifyMu.Lock(); logNotifyEnabled = previousNotify; logNotifyMu.Unlock() }()

	const batches = 256
	burstDone := make(chan struct{})
	go func() {
		defer close(burstDone)
		batch := make([]Message, messageBatchSize)
		for i := range batch {
			batch[i] = Message{Type: LogMessage, Data: strings.Repeat("synthetic-log-", 32)}
		}
		for i := 0; i < batches; i++ {
			sendMessageBatch(batch)
		}
	}()
	for i, method := range []CoreMethod{stopLogNotifyMethod, getTrafficMethod, getTotalTrafficMethod} {
		arguments := any(false)
		if method == stopLogNotifyMethod {
			arguments = nil
		}
		data, err := json.Marshal(map[string]any{"id": fmt.Sprint(i), "method": method, "arguments": arguments})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writeFrame(host, data); err != nil {
			t.Fatal(err)
		}
	}
	if c, ok := host.(interface{ SetReadDeadline(time.Time) error }); ok {
		_ = c.SetReadDeadline(deadline)
	}
	responses := map[string]bool{}
	logs := 0
	for len(responses) < 3 || logs < batches {
		data, err := readFrame(host)
		if err != nil {
			t.Fatalf("RPC/log channel failed during burst: replies=%d batches=%d err=%v", len(responses), logs, err)
		}
		var frame struct {
			ID     *string      `json:"id"`
			Method string       `json:"method"`
			Error  *MethodError `json:"error"`
		}
		if err := json.Unmarshal(data, &frame); err != nil {
			t.Fatal(err)
		}
		if frame.ID != nil {
			if frame.Error != nil {
				t.Fatalf("RPC rejected: %v", frame.Error)
			}
			responses[*frame.ID] = true
		} else {
			logs++
		}
	}
	select {
	case <-burstDone:
	case <-time.After(time.Second):
		t.Fatal("log producer stuck")
	}
	if len(responses) != 3 || logs != batches {
		t.Fatalf("replies=%d batches=%d", len(responses), logs)
	}
}
