package node

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/conf"
)

// caSignedLeafPEM returns a certificate that looks like an ACME-issued one:
// its issuer is a separate CA, not itself.
func caSignedLeafPEM(t *testing.T, domain string, days int) []byte {
	t.Helper()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate ca key: %v", err)
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(1, 0, 0),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create ca certificate: %v", err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatalf("parse ca certificate: %v", err)
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: domain},
		DNSNames:     []string{domain},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(0, 0, days),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create leaf certificate: %v", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER})
}

func writeCertPair(t *testing.T, certPEM, keyPEM []byte) (string, string) {
	t.Helper()
	dir := t.TempDir()
	certFile := path.Join(dir, "fullchain.pem")
	keyFile := path.Join(dir, "privkey.pem")
	if err := os.WriteFile(certFile, certPEM, 0644); err != nil {
		t.Fatalf("seed certificate: %v", err)
	}
	if err := os.WriteFile(keyFile, keyPEM, 0600); err != nil {
		t.Fatalf("seed key: %v", err)
	}
	return certFile, keyFile
}

func fallbackTestConfig(t *testing.T, domain string) *conf.CertConfig {
	t.Helper()
	dir := t.TempDir()
	return &conf.CertConfig{
		CertMode:   "http",
		CertDomain: domain,
		CertFile:   path.Join(dir, "fullchain.pem"),
		KeyFile:    path.Join(dir, "privkey.pem"),
	}
}

// stubACMEIssue swaps the issuance step so the fallback and upgrade paths can
// be tested without an ACME server. It is called from cleanups, so individual
// tests cannot interleave.
func stubACMEIssue(t *testing.T, fn func(*conf.CertConfig) error) *int {
	t.Helper()
	calls := 0
	old := acmeIssue
	acmeIssue = func(cert *conf.CertConfig) error {
		calls++
		return fn(cert)
	}
	t.Cleanup(func() { acmeIssue = old })
	return &calls
}

func TestIsSelfSignedCertificatePEM(t *testing.T) {
	dir := t.TempDir()
	certPEM, _, err := generateSelfSslCertificatePEM("tw3.stpikit.com")
	if err != nil {
		t.Fatalf("generate self-signed certificate: %v", err)
	}
	if !isSelfSignedCertificatePEM(certPEM) {
		t.Fatal("a locally generated certificate must be detected as self-signed")
	}
	if isSelfSignedCertificatePEM(caSignedLeafPEM(t, "tw3.stpikit.com", 90)) {
		t.Fatal("a CA-issued certificate must not be detected as self-signed")
	}
	if isSelfSignedCertificatePEM([]byte("not a certificate")) {
		t.Fatal("garbage must not be detected as self-signed")
	}
	missing := path.Join(dir, "absent.pem")
	if selfSignedCertificateFile(missing) {
		t.Fatal("a missing certificate file must not be reported as self-signed")
	}
}

func TestInstallSelfSignedCertificateWritesUsablePair(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	// A stale, longer file at the target path must be replaced completely
	// rather than partially overwritten.
	err := os.WriteFile(cert.CertFile, []byte(strings.Repeat("stale", 4096)), 0644)
	if err != nil {
		t.Fatalf("seed stale certificate: %v", err)
	}
	if err := installSelfSignedCertificate(cert); err != nil {
		t.Fatalf("install self-signed certificate: %v", err)
	}

	certPEM, err := os.ReadFile(cert.CertFile)
	if err != nil {
		t.Fatalf("read certificate: %v", err)
	}
	keyPEM, err := os.ReadFile(cert.KeyFile)
	if err != nil {
		t.Fatalf("read key: %v", err)
	}
	if !isSelfSignedCertificatePEM(certPEM) {
		t.Fatal("the installed certificate must be self-signed")
	}
	parsed, err := parseFirstCertificate(certPEM)
	if err != nil {
		t.Fatalf("parse installed certificate: %v", err)
	}
	if len(parsed.DNSNames) != 1 || parsed.DNSNames[0] != "tw3.stpikit.com" {
		t.Fatalf("certificate must cover the node domain, got %v", parsed.DNSNames)
	}
	block, _ := pem.Decode(keyPEM)
	if block == nil || block.Type != "RSA PRIVATE KEY" {
		t.Fatalf("key must be a labelled RSA PEM block, got %v", block)
	}
	if _, err := x509.ParsePKCS1PrivateKey(block.Bytes); err != nil {
		t.Fatalf("key must parse as PKCS1 RSA: %v", err)
	}
	if daysLeft, ok := certificateDaysLeft(cert.CertFile); !ok || daysLeft < 3650 {
		t.Fatalf("the fallback certificate must be long lived, got %d days (ok=%v)", daysLeft, ok)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(cert.KeyFile)
		if err != nil {
			t.Fatalf("stat key: %v", err)
		}
		if info.Mode().Perm() != 0600 {
			t.Fatalf("private key must not be world readable, got %v", info.Mode().Perm())
		}
	}
	if _, err := os.Stat(cert.CertFile + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("the atomic write must not leave a temporary file behind")
	}
}

func TestInstallSelfSignedCertificateCreatesParentDirectory(t *testing.T) {
	dir := t.TempDir()
	cert := &conf.CertConfig{
		CertDomain: "tw3.stpikit.com",
		CertFile:   path.Join(dir, "nested", "fullchain.pem"),
		KeyFile:    path.Join(dir, "nested", "privkey.pem"),
	}
	if err := installSelfSignedCertificate(cert); err != nil {
		t.Fatalf("install must create the certificate directory: %v", err)
	}
	if !selfSignedCertificateFile(cert.CertFile) {
		t.Fatal("certificate not installed in the created directory")
	}
}

func TestInstallSelfSignedCertificateRequiresDomain(t *testing.T) {
	cert := fallbackTestConfig(t, "")
	if err := installSelfSignedCertificate(cert); err == nil {
		t.Fatal("a self-signed fallback without a domain must be refused")
	}
	if _, err := os.Stat(cert.CertFile); !os.IsNotExist(err) {
		t.Fatal("no certificate file may be written without a domain")
	}
}

func TestHandleACMEIssuanceFailureFallsBackToSelfSigned(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	ctrl := newCertTestController(cert, "node_3")

	err := ctrl.handleACMEIssuanceFailure(errors.New("acme: http-01 challenge failed, port 80 unreachable"))
	if err != nil {
		t.Fatalf("a failed issuance must not block the node by default, got %v", err)
	}
	if !selfSignedCertificateFile(cert.CertFile) {
		t.Fatal("a self-signed certificate must be installed as the fallback")
	}
	if _, err := os.Stat(cert.KeyFile); err != nil {
		t.Fatalf("the fallback key must be installed: %v", err)
	}
}

func TestHandleACMEIssuanceFailureStrictKeepsError(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	cert.StrictACMEFailure = true
	ctrl := newCertTestController(cert, "node_3")
	cause := errors.New("acme: http-01 challenge failed, port 80 unreachable")

	err := ctrl.handleACMEIssuanceFailure(cause)
	if !errors.Is(err, cause) {
		t.Fatalf("strict mode must report the issuance failure, got %v", err)
	}
	if _, err := os.Stat(cert.CertFile); !os.IsNotExist(err) {
		t.Fatal("strict mode must not install a self-signed certificate")
	}
}

func TestHandleACMEIssuanceFailureWithoutDomainKeepsError(t *testing.T) {
	cert := fallbackTestConfig(t, "")
	ctrl := newCertTestController(cert, "node_3")
	cause := errors.New("acme: invalid domain")

	if err := ctrl.handleACMEIssuanceFailure(cause); !errors.Is(err, cause) {
		t.Fatalf("without a domain the original failure must surface, got %v", err)
	}
}

func TestRequestCertInstallsFallbackWhenIssuanceFails(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	ctrl := newCertTestController(cert, "node_3")
	calls := stubACMEIssue(t, func(*conf.CertConfig) error {
		return errors.New("acme: http-01 challenge failed, port 80 unreachable")
	})

	if err := ctrl.requestCert(); err != nil {
		t.Fatalf("requestCert must keep the node startable: %v", err)
	}
	if *calls != 1 {
		t.Fatalf("issuance must be attempted once, got %d", *calls)
	}
	if !selfSignedCertificateFile(cert.CertFile) {
		t.Fatal("requestCert must leave a self-signed certificate behind")
	}
}

func TestRequestCertSkipsIssuanceWhenCertificateExists(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	certPEM, _, err := generateSelfSslCertificatePEM(cert.CertDomain)
	if err != nil {
		t.Fatalf("generate certificate: %v", err)
	}
	if err := os.WriteFile(cert.CertFile, certPEM, 0644); err != nil {
		t.Fatalf("seed certificate: %v", err)
	}
	if err := os.WriteFile(cert.KeyFile, []byte("key"), 0600); err != nil {
		t.Fatalf("seed key: %v", err)
	}
	ctrl := newCertTestController(cert, "node_3")
	calls := stubACMEIssue(t, func(*conf.CertConfig) error {
		t.Fatal("an existing certificate must not trigger a new order on every node reload")
		return nil
	})

	if err := ctrl.requestCert(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if *calls != 0 {
		t.Fatalf("issuance must be skipped, got %d calls", *calls)
	}
}

func TestRenewCertTaskUpgradesSelfSignedCertificate(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	certPEM, keyPEM, err := generateSelfSslCertificatePEM(cert.CertDomain)
	if err != nil {
		t.Fatalf("generate self-signed certificate: %v", err)
	}
	cert.CertFile, cert.KeyFile = writeCertPair(t, certPEM, keyPEM)
	ctrl := newCertTestController(cert, "node_3")
	calls := stubACMEIssue(t, func(c *conf.CertConfig) error {
		// A successful issuance replaces the placeholder with a CA-issued chain.
		leaf := caSignedLeafPEM(t, c.CertDomain, 90)
		return writeCertificateFiles(c.CertFile, c.KeyFile, leaf, []byte("key"))
	})

	if err := ctrl.renewCertTask(); err != nil {
		t.Fatalf("renewal must not fail the task: %v", err)
	}
	if *calls != 1 {
		t.Fatalf("a self-signed certificate must trigger a new issuance, got %d calls", *calls)
	}
	if selfSignedCertificateFile(cert.CertFile) {
		t.Fatal("the placeholder must be replaced once issuance succeeds")
	}
}

func TestRenewCertTaskKeepsSelfSignedCertificateWhenUpgradeFails(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	certPEM, keyPEM, err := generateSelfSslCertificatePEM(cert.CertDomain)
	if err != nil {
		t.Fatalf("generate self-signed certificate: %v", err)
	}
	cert.CertFile, cert.KeyFile = writeCertPair(t, certPEM, keyPEM)
	before, err := os.ReadFile(cert.CertFile)
	if err != nil {
		t.Fatalf("read certificate: %v", err)
	}
	ctrl := newCertTestController(cert, "node_3")
	stubACMEIssue(t, func(*conf.CertConfig) error {
		return errors.New("acme: http-01 challenge failed, port 80 unreachable")
	})

	if err := ctrl.renewCertTask(); err != nil {
		t.Fatalf("renewal must not fail the task: %v", err)
	}
	after, err := os.ReadFile(cert.CertFile)
	if err != nil {
		t.Fatalf("read certificate: %v", err)
	}
	if string(before) != string(after) {
		t.Fatal("a still-valid placeholder must be kept as it is while issuance fails")
	}
}

func TestRenewCertTaskRefreshesSelfSignedCertificateBeforeExpiry(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	// A placeholder that is about to expire: issuance still fails, so the task
	// has to refresh the local certificate to keep TLS usable.
	expiring, keyPEM, err := selfSignedCertPEMWithValidity(t, cert.CertDomain, 5)
	if err != nil {
		t.Fatalf("generate near-expiry certificate: %v", err)
	}
	cert.CertFile, cert.KeyFile = writeCertPair(t, expiring, keyPEM)
	ctrl := newCertTestController(cert, "node_3")
	stubACMEIssue(t, func(*conf.CertConfig) error {
		return errors.New("acme: http-01 challenge failed, port 80 unreachable")
	})

	if err := ctrl.renewCertTask(); err != nil {
		t.Fatalf("renewal must not fail the task: %v", err)
	}
	daysLeft, ok := certificateDaysLeft(cert.CertFile)
	if !ok || daysLeft < selfSignedRefreshDays {
		t.Fatalf("a near-expiry placeholder must be refreshed, got %d days (ok=%v)", daysLeft, ok)
	}
}

func TestRenewCertTaskLeavesIssuedCertificateToNormalRenewal(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	// A CA-issued certificate that is still valid for months: the task must take
	// the normal renewal path (which skips it) and must not start a new order.
	cert.CertFile, cert.KeyFile = writeCertPair(t, caSignedLeafPEM(t, cert.CertDomain, 90), []byte("key"))
	writeLegoUserFile(t, cert.CertFile, "acme@tw3.stpikit.com")
	cert.Email = "acme@tw3.stpikit.com"
	ctrl := newCertTestController(cert, "node_3")
	calls := stubACMEIssue(t, func(*conf.CertConfig) error {
		t.Fatal("a healthy ACME certificate must not be re-issued by the fallback path")
		return nil
	})

	if err := ctrl.renewCertTask(); err != nil {
		t.Fatalf("renewal must not fail the task: %v", err)
	}
	if *calls != 0 {
		t.Fatalf("no issuance may be attempted for a valid certificate, got %d calls", *calls)
	}
}

func TestFallbackRecordTracksDegradationAndRecovery(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	ctrl := newCertTestController(cert, "node_3")

	err := ctrl.handleACMEIssuanceFailure(errors.New("acme: http-01 challenge failed, port 80 unreachable"))
	if err != nil {
		t.Fatalf("a failed issuance must not block the node by default, got %v", err)
	}
	data, err := os.ReadFile(certFallbackRecordPath(cert.CertFile))
	if err != nil {
		t.Fatalf("the fallback record must be written for the panel alert: %v", err)
	}
	var record certFallbackRecord
	if err := json.Unmarshal(data, &record); err != nil {
		t.Fatalf("fallback record must be valid json: %v", err)
	}
	if record.Domain != "tw3.stpikit.com" {
		t.Fatalf("fallback record must name the domain, got %q", record.Domain)
	}
	if !strings.Contains(record.Error, "port 80") {
		t.Fatalf("fallback record must carry the reason, got %q", record.Error)
	}
	if record.At == "" {
		t.Fatal("fallback record must carry a timestamp")
	}

	stubACMEIssue(t, func(c *conf.CertConfig) error {
		return writeCertificateFiles(c.CertFile, c.KeyFile, caSignedLeafPEM(t, c.CertDomain, 90), []byte("key"))
	})
	if err := ctrl.renewCertTask(); err != nil {
		t.Fatalf("renewal must not fail the task: %v", err)
	}
	if _, err := os.Stat(certFallbackRecordPath(cert.CertFile)); !os.IsNotExist(err) {
		t.Fatal("the fallback record must be removed once issuance succeeds")
	}
}

func TestApplyPanelTLSConfigClearsFallbackRecord(t *testing.T) {
	pushDir := t.TempDir()
	certPEM, keyPEM := selfSignedPEM(t, "tw3.stpikit.com")
	if err := os.WriteFile(path.Join(pushDir, "cert.pem"), []byte(certPEM), 0644); err != nil {
		t.Fatalf("seed pushed certificate: %v", err)
	}
	if err := os.WriteFile(path.Join(pushDir, "key.pem"), []byte(keyPEM), 0600); err != nil {
		t.Fatalf("seed pushed key: %v", err)
	}
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	cert.PanelPushDir = pushDir
	// The node had degraded to a self-signed placeholder before the panel
	// pushed real material: the marker must not outlive it, or the panel keeps
	// alerting about an issuance failure that is already resolved.
	if err := os.WriteFile(certFallbackRecordPath(cert.CertFile), []byte(`{"domain":"tw3.stpikit.com"}`), 0644); err != nil {
		t.Fatalf("seed fallback record: %v", err)
	}

	ctrl := newCertTestController(cert, "node_3")
	if err := ctrl.applyPanelTLSConfig(anytlsNode("tw3.stpikit.com", "updates.cdn-apple.com")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := os.Stat(certFallbackRecordPath(cert.CertFile)); !os.IsNotExist(err) {
		t.Fatal("a panel-pushed certificate must clear the ACME fallback marker")
	}
	if _, err := os.Stat(cert.CertFile); err != nil {
		t.Fatalf("the pushed certificate must be installed: %v", err)
	}
}

func TestRenewCertTaskLeavesPanelPushedCertificateAlone(t *testing.T) {
	cert := fallbackTestConfig(t, "tw3.stpikit.com")
	cert.PanelPush = true
	// Panel-pushed material stays under operator control even when it is
	// self-signed: the renewal task must not start ACME orders behind it.
	cert.CertFile, cert.KeyFile = writeCertPair(t, caSignedLeafPEM(t, cert.CertDomain, 90), []byte("key"))
	writeLegoUserFile(t, cert.CertFile, "acme@tw3.stpikit.com")
	cert.Email = "acme@tw3.stpikit.com"
	ctrl := newCertTestController(cert, "node_3")
	calls := stubACMEIssue(t, func(*conf.CertConfig) error {
		t.Fatal("panel-pushed certificates must not be re-issued automatically")
		return nil
	})

	if err := ctrl.renewCertTask(); err != nil {
		t.Fatalf("renewal must not fail the task: %v", err)
	}
	if *calls != 0 {
		t.Fatalf("no issuance may be attempted for pushed material, got %d calls", *calls)
	}
}

func selfSignedCertPEMWithValidity(t *testing.T, domain string, days int) (certPEM, keyPEM []byte, err error) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(3),
		Subject:               pkix.Name{CommonName: domain},
		DNSNames:              []string{domain},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(0, 0, days),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, key.Public(), key)
	if err != nil {
		return nil, nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}), nil
}

// writeLegoUserFile seeds the ACME account file so that the renewal path can
// build a client without registering a new account over the network.
func writeLegoUserFile(t *testing.T, certFile, email string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate account key: %v", err)
	}
	encoded, err := EncodePrivate(key)
	if err != nil {
		t.Fatalf("encode account key: %v", err)
	}
	data, err := json.Marshal(User{Email: email, KeyEncoded: encoded})
	if err != nil {
		t.Fatalf("marshal account: %v", err)
	}
	dir := path.Join(path.Dir(certFile), "user")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatalf("create account dir: %v", err)
	}
	if err := os.WriteFile(path.Join(dir, "user-"+email+".json"), data, 0644); err != nil {
		t.Fatalf("write account file: %v", err)
	}
}
