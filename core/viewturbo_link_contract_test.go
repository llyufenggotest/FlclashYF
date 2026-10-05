package main

import (
	"fmt"
	"strings"
	"testing"

	shadowsocks "github.com/metacubex/sing-shadowsocks2"
)

const viewTurboCipher = "chacha20-ietf-poly1305"

func TestViewTurboWrapperIsLinkedIntoCoreModule(t *testing.T) {
	method, err := shadowsocks.CreateMethod(viewTurboCipher, shadowsocks.MethodOptions{
		Password: "contract-token#VT",
	})
	if err != nil {
		t.Fatalf("CreateMethod(%s) with a #VT password failed: %v", viewTurboCipher, err)
	}

	typeName := fmt.Sprintf("%T", method)
	if !strings.Contains(typeName, "viewTurbo") {
		t.Fatalf(
			"ViewTurbo wrapper is NOT linked into the core module: CreateMethod returned %s.\n"+
				"The core module is resolving github.com/metacubex/sing-shadowsocks2 to the upstream\n"+
				"proxy cache instead of ./sing-shadowsocks2. Add this to core/go.mod:\n"+
				"    replace github.com/metacubex/sing-shadowsocks2 => ./sing-shadowsocks2",
			typeName,
		)
	}
}

func TestNonViewTurboPasswordKeepsUpstreamMethod(t *testing.T) {
	method, err := shadowsocks.CreateMethod(viewTurboCipher, shadowsocks.MethodOptions{
		Password: "an-ordinary-shadowsocks-password",
	})
	if err != nil {
		t.Fatalf("CreateMethod(%s) with a plain password failed: %v", viewTurboCipher, err)
	}

	typeName := fmt.Sprintf("%T", method)
	if strings.Contains(typeName, "viewTurbo") {
		t.Fatalf(
			"plain Shadowsocks nodes must not be wrapped in the ViewTurbo transport, got %s",
			typeName,
		)
	}
}
