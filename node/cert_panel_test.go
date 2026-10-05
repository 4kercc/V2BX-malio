package node

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path"
	"strings"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
)

func selfSignedPEM(t *testing.T, domain string) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: domain},
		DNSNames:              []string{domain},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().AddDate(1, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	certPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	keyPEM := string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}))
	return certPEM, keyPEM
}

// anytlsNode mirrors the real SSPanel response
// server="tw3.stpikit.com;port=443&server_name=updates.cdn-apple.com&insecure=1",
// where host is the landing domain and serverName is the masquerade SNI.
func anytlsNode(host, serverName string) *panel.NodeInfo {
	common := panel.CommonNode{Host: host, ServerPort: 443, ServerName: serverName}
	return &panel.NodeInfo{
		Type:         "anytls",
		Security:     panel.Tls,
		AnyTls:       &panel.AnyTlsNode{CommonNode: common},
		Common:       &common,
		PushInterval: time.Minute,
		PullInterval: time.Minute,
	}
}

func newCertTestController(cert *conf.CertConfig, tag string) *Controller {
	return &Controller{
		tag: tag,
		Options: &conf.Options{
			CertConfig: cert,
		},
	}
}

func TestCertDomainFromNodeUsesLandingHost(t *testing.T) {
	node := anytlsNode("tw3.stpikit.com", "updates.cdn-apple.com")
	if got := certDomainFromNode(node); got != "tw3.stpikit.com" {
		t.Fatalf("certificate domain must come from the landing host, got %q", got)
	}
}

func TestCertDomainFromNodeIgnoresMasqueradeSNIWhenHostIsIP(t *testing.T) {
	node := anytlsNode("203.0.113.10", "updates.cdn-apple.com")
	if got := certDomainFromNode(node); got != "" {
		t.Fatalf("a masquerade SNI is not an issuable certificate name, got %q", got)
	}
}

func TestNormalizeCertDomain(t *testing.T) {
	cases := map[string]string{
		"TW3.Stpikit.com:443": "tw3.stpikit.com",
		"tw3.stpikit.com.":    "tw3.stpikit.com",
		"203.0.113.10":        "",
		"[2001:db8::1]:8443":  "",
		"localhost":           "",
		"":                    "",
	}
	for input, want := range cases {
		if got := normalizeCertDomain(input); got != want {
			t.Fatalf("normalizeCertDomain(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestFillCertDefaultsForDomainUsesTemplate(t *testing.T) {
	cert := &conf.CertConfig{CertFile: "/etc/certs/{domain}/full.pem"}
	fillCertDefaultsForDomain(cert, "tw3.stpikit.com")
	if cert.CertFile != "/etc/certs/tw3.stpikit.com/full.pem" {
		t.Fatalf("template not resolved: %q", cert.CertFile)
	}
	if cert.KeyFile != path.Join("/etc/V2bX/cert", "tw3.stpikit.com", "privkey.pem") {
		t.Fatalf("expected derived key path, got %q", cert.KeyFile)
	}
}

func TestApplyPanelTLSConfigAdoptsLandingDomainAndEnablesACMEMode(t *testing.T) {
	cert := &conf.CertConfig{}
	ctrl := newCertTestController(cert, "node_3")
	node := anytlsNode("tw3.stpikit.com", "updates.cdn-apple.com")

	err := ctrl.applyPanelTLSConfig(node)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cert.AutoFromPanel {
		t.Fatal("auto mode should be recorded when the panel supplies the domain")
	}
	if cert.CertMode != "http" {
		t.Fatalf("expected ACME http mode, got %q", cert.CertMode)
	}
	if cert.CertDomain != "tw3.stpikit.com" {
		t.Fatalf("expected the landing domain, got %q", cert.CertDomain)
	}
	if strings.Contains(cert.CertDomain, "cdn-apple") {
		t.Fatal("the masquerade SNI must never be used as a certificate domain")
	}
	if cert.Email == "" {
		t.Fatal("an ACME contact email should be derived")
	}
	if !strings.Contains(cert.CertFile, "tw3.stpikit.com") {
		t.Fatalf("certificate path should be domain-scoped, got %q", cert.CertFile)
	}
}

func TestApplyPanelTLSConfigNeverOverridesOperatorMode(t *testing.T) {
	cert := &conf.CertConfig{CertMode: "dns", Provider: "cloudflare", CertFile: "/tmp/c.pem", KeyFile: "/tmp/k.key"}
	ctrl := newCertTestController(cert, "node_3")

	if err := ctrl.applyPanelTLSConfig(anytlsNode("tw3.stpikit.com", "updates.cdn-apple.com")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cert.CertMode != "dns" || cert.Provider != "cloudflare" {
		t.Fatalf("operator settings must win, got mode=%q provider=%q", cert.CertMode, cert.Provider)
	}
	if cert.AutoFromPanel {
		t.Fatal("an explicit operator mode must not be flagged as panel-driven")
	}
	if cert.CertDomain != "tw3.stpikit.com" {
		t.Fatalf("the landing domain should still be adopted, got %q", cert.CertDomain)
	}
	if cert.CertFile != "/tmp/c.pem" {
		t.Fatalf("explicit file paths must be preserved, got %q", cert.CertFile)
	}
}

func TestApplyPanelTLSConfigIgnoresCleartextNode(t *testing.T) {
	cert := &conf.CertConfig{}
	ctrl := newCertTestController(cert, "node_3")
	node := anytlsNode("tw3.stpikit.com", "updates.cdn-apple.com")
	node.Security = panel.None

	if err := ctrl.applyPanelTLSConfig(node); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cert.AutoFromPanel || cert.CertMode != "" {
		t.Fatal("a cleartext node must not trigger the certificate chain")
	}
}

func TestApplyPanelTLSConfigWithoutDomainKeepsNodeUsable(t *testing.T) {
	cert := &conf.CertConfig{}
	ctrl := newCertTestController(cert, "node_3")

	if err := ctrl.applyPanelTLSConfig(anytlsNode("203.0.113.10", "updates.cdn-apple.com")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cert.CertMode != "" || cert.AutoFromPanel {
		t.Fatal("no issuable domain means no automatic certificate mode")
	}
}

func TestApplyPanelTLSConfigInstallsPushedCertificate(t *testing.T) {
	dir := t.TempDir()
	certPEM, keyPEM := selfSignedPEM(t, "tw3.stpikit.com")
	err := os.WriteFile(path.Join(dir, "cert.pem"), []byte(certPEM), 0644)
	if err != nil {
		t.Fatalf("seed cert: %v", err)
	}
	err = os.WriteFile(path.Join(dir, "key.pem"), []byte(keyPEM), 0644)
	if err != nil {
		t.Fatalf("seed key: %v", err)
	}

	outDir := t.TempDir()
	cert := &conf.CertConfig{
		PanelPushDir: dir,
		CertFile:     path.Join(outDir, "node.crt"),
		KeyFile:      path.Join(outDir, "node.key"),
	}
	ctrl := newCertTestController(cert, "node_3")

	if err := ctrl.applyPanelTLSConfig(anytlsNode("tw3.stpikit.com", "updates.cdn-apple.com")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cert.PanelPush {
		t.Fatal("panel push should be recorded")
	}
	written, err := os.ReadFile(cert.CertFile)
	if err != nil {
		t.Fatalf("pushed certificate not installed: %v", err)
	}
	if string(written) != certPEM {
		t.Fatal("installed certificate differs from the pushed payload")
	}
	writtenKey, err := os.ReadFile(cert.KeyFile)
	if err != nil {
		t.Fatalf("pushed key not installed: %v", err)
	}
	if string(writtenKey) != keyPEM {
		t.Fatal("installed key differs from the pushed payload")
	}
	if err := ctrl.applyPanelTLSConfig(anytlsNode("tw3.stpikit.com", "updates.cdn-apple.com")); err != nil {
		t.Fatalf("re-applying pushed material must stay idempotent: %v", err)
	}
}

func TestWritePushedCertificateRejectsIncompletePayload(t *testing.T) {
	cert := &conf.CertConfig{CertFile: path.Join(t.TempDir(), "c.pem"), KeyFile: path.Join(t.TempDir(), "k.pem")}
	err := writePushedCertificate(panelTLSMaterial{Domain: "example.com", Certificate: "only-cert"}, cert)
	if err == nil {
		t.Fatal("an incomplete payload must be rejected")
	}
}
