package main

// ViewTurbo (`#VT`) is implemented as a local fork of sing-shadowsocks2 that
// lives at core/sing-shadowsocks2. A fork only takes effect through a `replace`
// directive in the MAIN module's go.mod, and the main module compiled into
// libclash.a / libclash_lowmem.a / libclash.so is `core` -- not `core/mihomo`.
//
// core/mihomo/go.mod already carries the replace, which makes every test run
// from inside core/mihomo pass while the shipped library silently links the
// pristine upstream v0.2.7 CreateMethod. That is exactly how ViewTurbo nodes
// reached production doing a plain Shadowsocks handshake: no fake HTTP header,
// no 60-byte token block, no salt inversion, no forced TCP split. The server
// rejects the stream, so the node shows no delay and carries no traffic.
//
// This contract fails loudly if the replace is ever dropped again.

import (
	"fmt"
	"strings"
	"testing"

	shadowsocks "github.com/metacubex/sing-shadowsocks2"
)

// viewTurboCipher matches the cipher every ViewTurbo subscription ships.
const viewTurboCipher = "chacha20-ietf-poly1305"

// TestViewTurboWrapperIsLinkedIntoCoreModule asserts that the ViewTurbo method
// wrapper is reachable from the `core` main module. Without the replace
// directive the returned method is the upstream shadowaead method and the
// wrapper type name is absent.
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

// TestNonViewTurboPasswordKeepsUpstreamMethod guards the other direction: the
// wrapper must not swallow ordinary Shadowsocks nodes. Blackstone ships plain
// `ss` nodes through the very same CreateMethod call.
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
