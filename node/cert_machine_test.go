package node

import (
	"os"
	"path"
	"strings"
	"testing"

	"github.com/InazumaV/V2bX/conf"
	"github.com/go-acme/lego/v4/certcrypto"
)

func machineTestNode(nodeID int, domain string) conf.NodeConfig {
	return conf.NodeConfig{
		ApiConfig: conf.ApiConfig{APIHost: "http://127.0.0.1", NodeID: nodeID, NodeType: "anytls"},
		Options: conf.Options{
			ListenIP: "0.0.0.0",
			SendIP:   "0.0.0.0",
			CertConfig: &conf.CertConfig{
				CertMode:   "http",
				CertDomain: domain,
			},
		},
	}
}

func TestMachineCertDomainsAutoCollectsNodeDomains(t *testing.T) {
	machine := &conf.CertConfig{CertMode: "http", CertDomains: []string{"auto"}}
	nodes := []conf.NodeConfig{
		machineTestNode(37, "hytron1.wukong.us.kg"),
		machineTestNode(38, "hytron1-1.wukong.us.kg"),
		machineTestNode(39, "hytron1.wukong.us.kg"), // duplicate must not repeat
	}

	if err := PrepareOptions(machine, nodes); err != nil {
		t.Fatalf("prepare: %v", err)
	}

	for i := range nodes {
		cert := nodes[i].Options.CertConfig
		if !cert.InheritFromMachine {
			t.Fatalf("node %d must inherit the machine certificate", nodes[i].ApiConfig.NodeID)
		}
		got := strings.Join(cert.DomainsOf(), ",")
		if got != "hytron1.wukong.us.kg,hytron1-1.wukong.us.kg" {
			t.Fatalf("node %d domains = %q, want both landing domains in order", nodes[i].ApiConfig.NodeID, got)
		}
		if cert.CertFile != path.Join("/etc/V2bX/cert/machine", "fullchain.pem") {
			t.Fatalf("node %d cert path = %q, want the shared machine path", nodes[i].ApiConfig.NodeID, cert.CertFile)
		}
		if cert.KeyFile != path.Join("/etc/V2bX/cert/machine", "privkey.pem") {
			t.Fatalf("node %d key path = %q", nodes[i].ApiConfig.NodeID, cert.KeyFile)
		}
		if cert.Email == "" {
			t.Fatal("an ACME contact email should be derived from the first domain")
		}
	}

	// Exactly one node issues and renews the shared certificate.
	owners := 0
	for i := range nodes {
		if nodes[i].Options.CertConfig.CertOwner {
			owners++
		}
	}
	if owners != 1 {
		t.Fatalf("expected exactly one certificate owner, got %d", owners)
	}
	if !nodes[0].Options.CertConfig.CertOwner {
		t.Fatal("the first inheriting node must be the owner")
	}
}

func TestMachineCertKeepsExplicitNodeSettings(t *testing.T) {
	machine := &conf.CertConfig{
		CertMode:   "dns",
		CertDomains: []string{"a.example.com", "b.example.com"},
		CertFile:   "/etc/V2bX/cert/machine/fullchain.pem",
		KeyFile:    "/etc/V2bX/cert/machine/privkey.pem",
		KeyType:    "ec-256",
		Provider:   "cloudflare",
		DNSEnv:     map[string]string{"CF_DNS_API_TOKEN": "token"},
	}
	manual := machineTestNode(37, "manual.example.com")
	manual.Options.CertConfig = &conf.CertConfig{
		CertMode:   "self",
		CertDomain: "manual.example.com",
		CertFile:   "/etc/ssl/manual.crt",
		KeyFile:    "/etc/ssl/manual.key",
	}
	inheriting := machineTestNode(38, "b.example.com")

	nodes := []conf.NodeConfig{manual, inheriting}
	if err := PrepareOptions(machine, nodes); err != nil {
		t.Fatalf("prepare: %v", err)
	}

	// An explicitly configured node keeps its own mode, paths and domain.
	if nodes[0].Options.CertConfig.CertMode != "self" || nodes[0].Options.CertConfig.CertFile != "/etc/ssl/manual.crt" {
		t.Fatalf("explicit node settings must win, got mode=%q cert=%q",
			nodes[0].Options.CertConfig.CertMode, nodes[0].Options.CertConfig.CertFile)
	}
	if nodes[0].Options.CertConfig.KeyType != "ec-256" || nodes[0].Options.CertConfig.Provider != "cloudflare" {
		t.Fatal("fields the node did not set must come from the machine block")
	}
	// The inheriting node gets the machine certificate, including the key type.
	if nodes[1].Options.CertConfig.CertFile != machine.CertFile || nodes[1].Options.CertConfig.KeyType != "ec-256" {
		t.Fatalf("inheriting node = %+v", nodes[1].Options.CertConfig)
	}
	if nodes[1].Options.CertConfig.CertOwner {
		t.Fatal("the owner must be the first inheriting node, not a later one")
	}
}

func TestMachineCertDisabledWithoutDomains(t *testing.T) {
	machine := &conf.CertConfig{CertMode: "http", CertDomains: []string{"auto"}}
	nodes := []conf.NodeConfig{machineTestNode(37, "")}

	if err := PrepareOptions(machine, nodes); err != nil {
		t.Fatalf("prepare: %v", err)
	}
	cert := nodes[0].Options.CertConfig
	if cert.InheritFromMachine {
		t.Fatal("without any domain the machine certificate must stay unused")
	}
	if cert.CertFile != "" {
		t.Fatalf("the node must keep its own (empty) paths, got %q", cert.CertFile)
	}
}

func TestSendIPAutoFollowsListenAddress(t *testing.T) {
	machine := &conf.CertConfig{CertMode: "http", CertDomains: []string{"a.example.com"}}

	concrete := machineTestNode(37, "a.example.com")
	concrete.Options.ListenIP = "45.196.221.58"
	concrete.Options.SendIP = "auto"

	wildcard := machineTestNode(38, "a.example.com")
	wildcard.Options.ListenIP = "0.0.0.0"
	wildcard.Options.SendIP = "auto"

	nodes := []conf.NodeConfig{concrete, wildcard}
	if err := PrepareOptions(machine, nodes); err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if nodes[0].Options.SendIP != "45.196.221.58" || !nodes[0].Options.SendIPAuto {
		t.Fatalf("SendIP=auto must follow the listen address, got %q", nodes[0].Options.SendIP)
	}
	if nodes[1].Options.SendIP != "0.0.0.0" {
		t.Fatalf("a wildcard listener cannot be a source address, got %q", nodes[1].Options.SendIP)
	}
}

func TestListenIPAutoResolvesLandingDomain(t *testing.T) {
	nodes := []conf.NodeConfig{machineTestNode(37, "localhost")}
	nodes[0].Options.ListenIP = "auto"
	nodes[0].Options.SendIP = "auto"

	if err := PrepareOptions(nil, nodes); err != nil {
		t.Fatalf("prepare: %v", err)
	}
	// "localhost" resolves through the hosts file, so this stays offline.
	if nodes[0].Options.ListenIP != "127.0.0.1" {
		t.Fatalf("ListenIP=auto 应解析落地域名的 A 记录，got %q", nodes[0].Options.ListenIP)
	}
	if nodes[0].Options.SendIP != "127.0.0.1" {
		t.Fatalf("SendIP=auto 应跟随解析出的监听地址，got %q", nodes[0].Options.SendIP)
	}
}

func TestListenIPAutoWithoutDomainFails(t *testing.T) {
	nodes := []conf.NodeConfig{machineTestNode(37, "")}
	nodes[0].Options.ListenIP = "auto"
	if err := PrepareOptions(nil, nodes); err == nil {
		t.Fatal("ListenIP=auto 没有域名可用时必须报错，而不是静默监听错误地址")
	}
}

func TestPrepareOptionsIsIdempotent(t *testing.T) {
	machine := &conf.CertConfig{CertMode: "http", CertDomains: []string{"a.example.com", "b.example.com"}}
	nodes := []conf.NodeConfig{machineTestNode(37, "localhost"), machineTestNode(38, "b.example.com")}
	nodes[0].Options.ListenIP = "auto"
	nodes[1].Options.SendIP = "auto"
	nodes[1].Options.ListenIP = "45.196.221.67"

	if err := PrepareOptions(machine, nodes); err != nil {
		t.Fatalf("prepare: %v", err)
	}
	first := make([]string, len(nodes))
	for i := range nodes {
		first[i] = nodes[i].Options.ListenIP + "|" + nodes[i].Options.SendIP + "|" + nodes[i].Options.CertConfig.CertFile
	}
	if err := PrepareOptions(machine, nodes); err != nil {
		t.Fatalf("second prepare: %v", err)
	}
	for i := range nodes {
		got := nodes[i].Options.ListenIP + "|" + nodes[i].Options.SendIP + "|" + nodes[i].Options.CertConfig.CertFile
		if got != first[i] {
			t.Fatalf("prepare 必须幂等：node %d 第一次 %q，第二次 %q", nodes[i].ApiConfig.NodeID, first[i], got)
		}
	}
}

func TestSelfSignedCertificateCoversAllDomains(t *testing.T) {
	certPEM, _, err := generateSelfSslCertificatePEM([]string{"a.example.com", "b.example.com"})
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	parsed, err := parseFirstCertificate(certPEM)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(parsed.DNSNames) != 2 || parsed.DNSNames[0] != "a.example.com" || parsed.DNSNames[1] != "b.example.com" {
		t.Fatalf("自签证书必须覆盖全部域名，got %v", parsed.DNSNames)
	}
	if parsed.Subject.CommonName != "a.example.com" {
		t.Fatalf("CN 取第一个域名，got %q", parsed.Subject.CommonName)
	}
}

func TestSelfSignedDomainsSkipsAutoPlaceholder(t *testing.T) {
	cert := &conf.CertConfig{CertDomains: []string{"auto"}}
	if got := selfSignedDomains(cert); len(got) != 0 {
		t.Fatalf("未解析的 auto 不能进证书，got %v", got)
	}
	cert = &conf.CertConfig{CertDomains: []string{"auto", "x.example.com"}}
	if got := selfSignedDomains(cert); len(got) != 1 || got[0] != "x.example.com" {
		t.Fatalf("auto 之外的域名要保留，got %v", got)
	}
	cert = &conf.CertConfig{CertDomain: "single.example.com"}
	if got := selfSignedDomains(cert); len(got) != 1 || got[0] != "single.example.com" {
		t.Fatalf("单域名写法必须继续可用，got %v", got)
	}
}

func TestInstallSelfSignedCertificateWritesMultiNameBundle(t *testing.T) {
	cert := fallbackTestConfig(t, "a.example.com")
	cert.CertDomains = []string{"a.example.com", "b.example.com"}
	if err := installSelfSignedCertificate(cert); err != nil {
		t.Fatalf("install: %v", err)
	}
	data, err := os.ReadFile(cert.CertFile)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	parsed, err := parseFirstCertificate(data)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(parsed.DNSNames) != 2 {
		t.Fatalf("兜底自签证书要覆盖机器上的全部域名，got %v", parsed.DNSNames)
	}
}

func TestCertKeyTypeMapping(t *testing.T) {
	cases := map[string]certcrypto.KeyType{
		"":          certcrypto.RSA2048, // 老配置不写 KeyType 时行为不变
		"rsa2048":   certcrypto.RSA2048,
		"ec-256":    certcrypto.EC256,
		"EC-384":    certcrypto.EC384,
		"rsa4096":   certcrypto.RSA4096,
		"garbage":   certcrypto.RSA2048,
	}
	for input, want := range cases {
		if got := certKeyType(input); got != want {
			t.Fatalf("certKeyType(%q) = %v, want %v", input, got, want)
		}
	}
}
