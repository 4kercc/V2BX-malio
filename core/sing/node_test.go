package sing

import (
	"encoding/base64"
	"encoding/pem"
	"strings"
	"testing"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
)

// anytlsNodeInfo models a real SSPanel AnyTLS response, e.g.
// server = "tw3.stpikit.com;port=443&server_name=updates.cdn-apple.com&insecure=1"
// where Common.Host is the landing domain and ServerName is the client-side
// masquerade SNI.
func anytlsNodeInfo(host, serverName string) *panel.NodeInfo {
	common := panel.CommonNode{Host: host, ServerPort: 443, ServerName: serverName}
	return &panel.NodeInfo{
		Type:     "anytls",
		Security: panel.Tls,
		AnyTls:   &panel.AnyTlsNode{CommonNode: common},
		Common:   &common,
	}
}

func anytlsOptions(cert *conf.CertConfig) *conf.Options {
	return &conf.Options{
		ListenIP:   "0.0.0.0",
		CertConfig: cert,
		SingOptions: &conf.SingOptions{
			TCPFastOpen: true,
		},
	}
}

func TestCertificateDomainUsesLandingHostNotMasqueradeSNI(t *testing.T) {
	got := certificateDomainFromNode(anytlsNodeInfo("tw3.stpikit.com", "updates.cdn-apple.com"))
	if got != "tw3.stpikit.com" {
		t.Fatalf("certificate domain must be the landing host, got %q", got)
	}
}

func TestCertificateDomainRejectsIPHost(t *testing.T) {
	if got := certificateDomainFromNode(anytlsNodeInfo("203.0.113.10", "updates.cdn-apple.com")); got != "" {
		t.Fatalf("an IP host is not issuable, got %q", got)
	}
}

func TestNormalizeDomainValue(t *testing.T) {
	cases := map[string]string{
		"TW3.Stpikit.com:443": "tw3.stpikit.com",
		"tw3.stpikit.com.":    "tw3.stpikit.com",
		"10.0.0.1":            "",
		"[2001:db8::1]:443":   "",
		"localhost":           "",
		"":                    "",
	}
	for input, want := range cases {
		if got := normalizeDomainValue(input); got != want {
			t.Fatalf("normalizeDomainValue(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestBuildInboundTLSUsesCertificateDomain(t *testing.T) {
	opts := anytlsOptions(&conf.CertConfig{
		CertMode: "http",
		CertFile: "/etc/V2bX/cert/tw3.stpikit.com/fullchain.pem",
		KeyFile:  "/etc/V2bX/cert/tw3.stpikit.com/privkey.pem",
	})
	tls, err := buildInboundTLS(anytlsNodeInfo("tw3.stpikit.com", "updates.cdn-apple.com"), opts)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !tls.Enabled {
		t.Fatal("tls should be enabled for ACME mode")
	}
	if tls.ServerName != "tw3.stpikit.com" {
		t.Fatalf("inbound TLS server name must be the landing domain, got %q", tls.ServerName)
	}
	if strings.Contains(tls.ServerName, "cdn-apple") {
		t.Fatal("the masquerade SNI must never leak into the inbound TLS configuration")
	}
	if tls.CertificatePath != "/etc/V2bX/cert/tw3.stpikit.com/fullchain.pem" {
		t.Fatalf("cert path not wired: %q", tls.CertificatePath)
	}
}

func TestBuildInboundTLSKeepsExplicitCertDomain(t *testing.T) {
	opts := anytlsOptions(&conf.CertConfig{
		CertMode:   "file",
		CertDomain: "local.example.com",
		CertFile:   "/etc/V2bX/cert.pem",
		KeyFile:    "/etc/V2bX/key.pem",
	})
	tls, err := buildInboundTLS(anytlsNodeInfo("tw3.stpikit.com", "updates.cdn-apple.com"), opts)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tls.ServerName != "local.example.com" {
		t.Fatalf("an explicit CertDomain wins, got %q", tls.ServerName)
	}
}

func TestBuildInboundTLSDisabledWithoutCertMode(t *testing.T) {
	opts := anytlsOptions(&conf.CertConfig{CertMode: "none"})
	tls, err := buildInboundTLS(anytlsNodeInfo("tw3.stpikit.com", "updates.cdn-apple.com"), opts)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tls.Enabled {
		t.Fatal("tls must stay disabled when cert_mode=none")
	}
}

func TestBuildInboundTLSCleartextWhenNoSecurity(t *testing.T) {
	node := anytlsNodeInfo("tw3.stpikit.com", "updates.cdn-apple.com")
	node.Security = panel.None
	tls, err := buildInboundTLS(node, anytlsOptions(&conf.CertConfig{CertMode: "file"}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tls.Enabled {
		t.Fatal("cleartext node must not enable tls")
	}
}

func TestBuildInboundTLSEchFromBase64KeySet(t *testing.T) {
	keySet := make([]byte, 64)
	for i := range keySet {
		keySet[i] = byte(i)
	}
	encoded := base64.StdEncoding.EncodeToString(keySet)
	opts := anytlsOptions(&conf.CertConfig{
		CertMode: "file",
		CertFile: "/etc/V2bX/cert.pem",
		KeyFile:  "/etc/V2bX/key.pem",
		ECHKey:   encoded,
	})
	tls, err := buildInboundTLS(anytlsNodeInfo("tw3.stpikit.com", "updates.cdn-apple.com"), opts)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tls.ECH == nil || !tls.ECH.Enabled {
		t.Fatal("ech should be enabled when a key set is configured")
	}
	if len(tls.ECH.Key) != 1 {
		t.Fatalf("expected a single ech key block, got %d", len(tls.ECH.Key))
	}
	block, rest := pem.Decode([]byte(tls.ECH.Key[0]))
	if block == nil || block.Type != "ECH KEYS" || len(strings.TrimSpace(string(rest))) > 0 {
		t.Fatalf("ech key must be a single ECH KEYS pem block, got type %v", block)
	}
	if string(block.Bytes) != string(keySet) {
		t.Fatal("ech key payload mismatch after base64 round trip")
	}
}

func TestBuildInboundTLSEchRejectsWhenTLSDisabled(t *testing.T) {
	opts := anytlsOptions(&conf.CertConfig{
		CertMode: "none",
		ECHKey:   base64.StdEncoding.EncodeToString([]byte("fake")),
	})
	if _, err := buildInboundTLS(anytlsNodeInfo("tw3.stpikit.com", "updates.cdn-apple.com"), opts); err == nil {
		t.Fatal("ech without tls must be rejected instead of silently ignored")
	}
}

func TestBuildECHKeyPEMPassesThroughExistingPEM(t *testing.T) {
	keySet := []byte{1, 2, 3, 4}
	original := string(pem.EncodeToMemory(&pem.Block{Type: "ECH KEYS", Bytes: keySet}))
	out, err := buildECHKeyPEM(original)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	block, rest := pem.Decode([]byte(out))
	if block == nil || block.Type != "ECH KEYS" || len(strings.TrimSpace(string(rest))) > 0 {
		t.Fatalf("pass-through must keep a single ECH KEYS block, got %v", block)
	}
	if string(block.Bytes) != string(keySet) {
		t.Fatal("pass-through changed the ech key payload")
	}
}

func TestBuildECHKeyPEMRejectsInvalidInput(t *testing.T) {
	if _, err := buildECHKeyPEM("not-base64!!!"); err == nil {
		t.Fatal("invalid base64 must be rejected")
	}
	wrongPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: []byte{1}}))
	if _, err := buildECHKeyPEM(wrongPEM); err == nil {
		t.Fatal("a non ECH KEYS pem block must be rejected")
	}
}
