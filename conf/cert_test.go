package conf

import "testing"

func TestCertDomainsOfSupportsBothForms(t *testing.T) {
	single := &CertConfig{CertDomain: "a.example.com"}
	if got := single.DomainsOf(); len(got) != 1 || got[0] != "a.example.com" {
		t.Fatalf("单域名写法必须继续可用，got %v", got)
	}
	multi := &CertConfig{CertDomain: "ignored.example.com", CertDomains: []string{" a.example.com ", "", "b.example.com"}}
	got := multi.DomainsOf()
	if len(got) != 2 || got[0] != "a.example.com" || got[1] != "b.example.com" {
		t.Fatalf("CertDomains 优先于 CertDomain 且要清理空白，got %v", got)
	}
	auto := &CertConfig{CertDomains: []string{"auto"}}
	if !auto.HasAutoDomain() {
		t.Fatal("auto 占位符应被识别")
	}
	if (&CertConfig{CertDomains: []string{"a.example.com"}}).HasAutoDomain() {
		t.Fatal("普通域名不应被识别成 auto")
	}
}

func TestMergeCertConfigFillsOnlyMissingFields(t *testing.T) {
	machine := &CertConfig{
		CertMode:         "dns",
		CertDomains:      []string{"a.example.com", "b.example.com"},
		CertFile:         "/etc/V2bX/cert/machine/fullchain.pem",
		KeyFile:          "/etc/V2bX/cert/machine/privkey.pem",
		KeyType:          "ec-256",
		Provider:         "cloudflare",
		Email:            "acme@example.com",
		DNSEnv:           map[string]string{"CF_DNS_API_TOKEN": "t"},
		RejectUnknownSni: true,
	}
	node := &CertConfig{
		CertMode:   "self",
		CertDomain: "node.example.com",
		CertFile:   "/etc/ssl/node.crt",
		KeyFile:    "/etc/ssl/node.key",
	}
	merged := MergeCertConfig(machine, node)

	if merged.CertMode != "self" || merged.CertFile != "/etc/ssl/node.crt" || merged.CertDomain != "node.example.com" {
		t.Fatalf("显式节点设置必须优先，got mode=%q cert=%q domain=%q", merged.CertMode, merged.CertFile, merged.CertDomain)
	}
	if merged.KeyType != "ec-256" || merged.Provider != "cloudflare" || merged.Email != "acme@example.com" {
		t.Fatalf("节点没写的字段应从机器级继承，got key=%q provider=%q email=%q", merged.KeyType, merged.Provider, merged.Email)
	}
	if len(merged.CertDomains) != 2 {
		t.Fatalf("域名列表应从机器级继承，got %v", merged.CertDomains)
	}
	if !merged.RejectUnknownSni {
		t.Fatal("机器级开关应向下继承")
	}
	if !merged.InheritFromMachine {
		t.Fatal("继承标记必须置位（用于只让 owner 节点签发/续期）")
	}
	if node.InheritFromMachine {
		t.Fatal("合并不能污染传入的节点配置")
	}
}

func TestMergeCertConfigWithoutMachineBlock(t *testing.T) {
	node := &CertConfig{CertMode: "self", CertDomain: "a.example.com"}
	if got := MergeCertConfig(nil, node); got != node {
		t.Fatal("没有机器级证书块时应原样返回节点配置")
	}
}
