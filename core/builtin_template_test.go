package main

import (
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"os"
	"path/filepath"
	"testing"
)

func TestBuiltinTemplateCoreSchema(t *testing.T) {
	data, err := os.ReadFile("../assets/data/profile_template.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if message := handleValidateConfig(string(data)); message != "" {
		t.Fatal(message)
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw.ProxyGroup) != 4 || len(raw.RuleProvider) != 1 {
		t.Fatal("unexpected template groups or providers")
	}
	expected := []string{"DST-PORT,123,🎯 全球直连", "RULE-SET,BanAD,REJECT", "GEOIP,CN,🎯 全球直连", "GEOSITE,CN,🎯 全球直连", "MATCH,🐟 漏网之鱼"}
	if len(raw.Rule) != len(expected) {
		t.Fatal("unexpected template rule count")
	}
	for i, rule := range expected {
		if raw.Rule[i] != rule {
			t.Fatalf("rule %d does not match user template", i)
		}
	}
}

func TestBuiltinTemplateCoreRuntime(t *testing.T) {
	if os.Getenv("FLCLASH_TEMPLATE_RUNTIME") != "1" {
		t.Skip("opt-in runtime parse downloads geodata into an isolated home")
	}
	data, err := os.ReadFile("../assets/data/profile_template.yaml")
	if err != nil {
		t.Fatal(err)
	}
	home := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(home) })
	if directory := os.Getenv("FLCLASH_TEMPLATE_GEODATA"); directory != "" {
		for _, file := range []string{"geoip.metadb", "geosite.dat"} {
			bytes, err := os.ReadFile(filepath.Join(directory, file))
			if err != nil {
				t.Fatal(err)
			}
			target := C.Path.MMDB()
			if file == "geosite.dat" {
				target = C.Path.GeoSite()
			}
			if err := os.WriteFile(target, bytes, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	raw.Proxy = []map[string]any{{"name": "Oppa fixture", "type": "oppa", "server": "example.com", "port": 443, "password": "synthetic-key"}}
	for _, group := range raw.ProxyGroup {
		if group["name"] == "⚡ 自动优选" {
			group["proxies"] = []string{"Oppa fixture"}
		}
	}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"🚀 节点选择", "🎯 全球直连", "🐟 漏网之鱼", "⚡ 自动优选"} {
		if parsed.Proxies[name] == nil {
			t.Fatalf("missing group %s", name)
		}
	}
	for _, provider := range parsed.Providers {
		if closer, ok := provider.(interface{ Close() error }); ok {
			_ = closer.Close()
		}
	}
	for _, provider := range parsed.RuleProviders {
		if closer, ok := provider.(interface{ Close() error }); ok {
			_ = closer.Close()
		}
	}
}
