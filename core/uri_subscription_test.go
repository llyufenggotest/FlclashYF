package main

import (
	"encoding/base64"
	"testing"
)

func TestHandleConvertURISubscriptionPlaintextAndBase64(t *testing.T) {
	line := "vless://00112233-4455-6677-8899-aabbccddeeff%23pure@example.com:443?type=ws&security=tls&alpn=http%2F1.1&path=%2Fwebsocket#Pure"
	for name, input := range map[string]string{
		"plaintext": line,
		"base64":    base64.StdEncoding.EncodeToString([]byte(line)),
	} {
		t.Run(name, func(t *testing.T) {
			proxies, err := handleConvertURISubscription(input)
			if err != nil {
				t.Fatal(err)
			}
			if len(proxies) != 1 {
				t.Fatalf("got %d proxies", len(proxies))
			}
			if got := proxies[0]["uuid"]; got != "00112233-4455-6677-8899-aabbccddeeff#pure" {
				t.Fatalf("uuid=%v", got)
			}
		})
	}
}

func TestHandleConvertURISubscriptionConvertsXlessToPure(t *testing.T) {
	line := "xless://05f20dc5-b168-47a3-a31e-4864fb0f7fbf@36.250.245.239:30149?security=tls&alpn=http/1.1&allowInsecure=1&type=ws&path=%2Fwebsocket&mode=xless#%F0%9F%87%BA%F0%9F%87%B8%20%E7%BE%8E%E5%9B%BD%2001"
	for name, input := range map[string]string{
		"plaintext": line,
		"base64":    base64.StdEncoding.EncodeToString([]byte(line)),
	} {
		t.Run(name, func(t *testing.T) {
			proxies, err := handleConvertURISubscription(input)
			if err != nil {
				t.Fatal(err)
			}
			if len(proxies) != 1 {
				t.Fatalf("got %d proxies", len(proxies))
			}
			proxy := proxies[0]
			if got := proxy["uuid"]; got != "05f20dc5-b168-47a3-a31e-4864fb0f7fbf#pure" {
				t.Fatalf("uuid=%v", got)
			}
			if proxy["server"] != "36.250.245.239" || proxy["port"] != "30149" {
				t.Fatalf("endpoint=%v:%v", proxy["server"], proxy["port"])
			}
			if proxy["network"] != "ws" || proxy["tls"] != true || proxy["skip-cert-verify"] != true {
				t.Fatalf("transport=%v", proxy)
			}
			if proxy["name"] != "🇺🇸 美国 01" {
				t.Fatalf("name=%v", proxy["name"])
			}
		})
	}
}

func TestHandleConvertURISubscriptionRejectsUnsupportedInput(t *testing.T) {
	_, err := handleConvertURISubscription("not a subscription")
	if err == nil {
		t.Fatal("unsupported input was accepted")
	}
}
