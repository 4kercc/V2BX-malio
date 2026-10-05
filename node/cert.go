package node

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path"
	"time"

	"github.com/InazumaV/V2bX/common/file"
	"github.com/InazumaV/V2bX/conf"
	log "github.com/sirupsen/logrus"
)

// certFallbackMarker prefixes every message about the self-signed fallback so
// the condition is easy to grep in the node log and in the cloud log stream.
const certFallbackMarker = "CERT-FALLBACK"

// selfSignedRefreshDays is the remaining lifetime at which a self-signed
// placeholder is regenerated while ACME issuance still fails. Certificates
// generated here last 30 years, but placeholders installed by hand or by an
// installer script can expire sooner, and an expired chain would break every
// client even when it skips verification.
const selfSignedRefreshDays = 15

// acmeIssue is the automatic issuance step used by requestCert and by the
// self-signed upgrade path. It is a variable so both can be exercised without
// talking to an ACME server.
var acmeIssue = func(cert *conf.CertConfig) error {
	l, err := NewLego(cert)
	if err != nil {
		return fmt.Errorf("create lego object error: %s", err)
	}
	err = l.CreateCert()
	if err != nil {
		return fmt.Errorf("create lego cert error: %s", err)
	}
	return nil
}

func (c *Controller) renewCertTask() error {
	cert := c.CertConfig
	if cert != nil && (cert.CertMode == "http" || cert.CertMode == "dns") {
		// A self-signed certificate is a placeholder: issuance failed earlier.
		// Keep retrying it here instead of renewing a certificate no CA knows
		// about, so a repaired DNS or a freed port 80 heals without a restart.
		// Material pushed by the panel is left alone: the operator owns it.
		if !cert.PanelPush && selfSignedCertificateFile(cert.CertFile) {
			return c.upgradeSelfSignedCertificate()
		}
	}
	l, err := NewLego(c.CertConfig)
	if err != nil {
		log.WithField("tag", c.tag).Info("new lego error: ", err)
		return nil
	}
	err = l.RenewCert()
	if err != nil {
		log.WithField("tag", c.tag).Info("renew cert error: ", err)
		return nil
	}
	return nil
}

func (c *Controller) requestCert() error {
	cert := c.CertConfig
	if cert == nil {
		return nil
	}
	switch cert.CertMode {
	case "none", "":
	case "file":
		if cert.CertFile == "" || cert.KeyFile == "" {
			return fmt.Errorf("cert file path or key file path not exist")
		}
	case "dns", "http":
		if cert.CertFile == "" || cert.KeyFile == "" {
			return fmt.Errorf("cert file path or key file path not exist")
		}
		if file.IsExist(cert.CertFile) && file.IsExist(cert.KeyFile) {
			return nil
		}
		err := acmeIssue(cert)
		if err != nil {
			return c.handleACMEIssuanceFailure(err)
		}
	case "self":
		if cert.CertFile == "" || cert.KeyFile == "" {
			return fmt.Errorf("cert file path or key file path not exist")
		}
		if file.IsExist(cert.CertFile) && file.IsExist(cert.KeyFile) {
			return nil
		}
		err := generateSelfSslCertificate(
			cert.CertDomain,
			cert.CertFile,
			cert.KeyFile)
		if err != nil {
			return fmt.Errorf("generate self cert error: %s", err)
		}
	default:
		return fmt.Errorf("unsupported certmode: %s", cert.CertMode)
	}
	return nil
}

// handleACMEIssuanceFailure decides what a failed automatic issuance means for
// the node. By default the node must still come up: a self-signed certificate
// for the same domain is installed and the failure is reported loudly, and the
// renewal task keeps retrying issuance. Setting CertConfig.StrictACMEFailure
// restores the historic behaviour of refusing to start.
func (c *Controller) handleACMEIssuanceFailure(cause error) error {
	cert := c.CertConfig
	if cert == nil || cert.StrictACMEFailure {
		return cause
	}
	if cert.CertDomain == "" || cert.CertFile == "" || cert.KeyFile == "" {
		// Without a domain there is no identity to sign for, and without file
		// paths there is nowhere to install a certificate. Report the original
		// failure instead of hiding it behind a broken fallback.
		return cause
	}
	log.WithFields(log.Fields{
		"tag":    c.tag,
		"domain": cert.CertDomain,
		"err":    cause,
	}).Warn(certFallbackMarker + ": ACME issuance failed, installing a self-signed certificate so the node can still start; clients that verify the chain will reject it until issuance succeeds (set CertConfig.StrictACMEFailure to fail startup instead)")
	err := installSelfSignedCertificate(cert)
	if err != nil {
		return fmt.Errorf("%s; "+certFallbackMarker+": self-signed certificate also failed: %s", cause, err)
	}
	writeCertFallbackRecord(cert, cause)
	log.WithFields(log.Fields{
		"tag":    c.tag,
		"domain": cert.CertDomain,
		"cert":   cert.CertFile,
	}).Warn(certFallbackMarker + ": node is serving a self-signed certificate; the daily renewal task keeps retrying ACME issuance")
	return nil
}

// upgradeSelfSignedCertificate replaces a self-signed placeholder with a real
// ACME certificate. It never fails the task: while issuance is impossible the
// node keeps serving the local certificate, which is refreshed before it
// expires so the inbound never presents an expired chain.
func (c *Controller) upgradeSelfSignedCertificate() error {
	cert := c.CertConfig
	err := acmeIssue(cert)
	if err == nil {
		removeCertFallbackRecord(cert)
		log.WithFields(log.Fields{
			"tag":    c.tag,
			"domain": cert.CertDomain,
			"cert":   cert.CertFile,
		}).Info("ACME issuance succeeded, the self-signed certificate has been replaced")
		return nil
	}
	log.WithFields(log.Fields{
		"tag":    c.tag,
		"domain": cert.CertDomain,
		"err":    err,
	}).Warn(certFallbackMarker + ": ACME issuance still failing, keeping the self-signed certificate")
	writeCertFallbackRecord(cert, err)
	daysLeft, ok := certificateDaysLeft(cert.CertFile)
	if ok && daysLeft < selfSignedRefreshDays {
		err = installSelfSignedCertificate(cert)
		if err != nil {
			log.WithFields(log.Fields{
				"tag": c.tag,
				"err": err,
			}).Error(certFallbackMarker + ": refresh of the self-signed certificate failed")
			return nil
		}
		log.WithFields(log.Fields{
			"tag":  c.tag,
			"cert": cert.CertFile,
		}).Warn(certFallbackMarker + ": self-signed certificate refreshed before expiry")
	}
	return nil
}

// installSelfSignedCertificate generates a self-signed certificate for
// CertDomain and installs it atomically at the configured paths.
func installSelfSignedCertificate(cert *conf.CertConfig) error {
	if cert.CertDomain == "" {
		return fmt.Errorf("no certificate domain available for a self-signed certificate")
	}
	if cert.CertFile == "" || cert.KeyFile == "" {
		return fmt.Errorf("cert file path or key file path not exist")
	}
	certPEM, keyPEM, err := generateSelfSslCertificatePEM(cert.CertDomain)
	if err != nil {
		return err
	}
	return writeCertificateFiles(cert.CertFile, cert.KeyFile, certPEM, keyPEM)
}

func generateSelfSslCertificate(domain, certPath, keyPath string) error {
	certPEM, keyPEM, err := generateSelfSslCertificatePEM(domain)
	if err != nil {
		return err
	}
	return writeCertificateFiles(certPath, keyPath, certPEM, keyPEM)
}

// generateSelfSslCertificatePEM builds a self-signed certificate for the
// domain. Its lifetime is 30 years, matching the historic CertMode=self
// behaviour, so a self-signed node never depends on renewal to stay usable.
// Callers use it both for an explicitly configured self-signed node and as the
// placeholder installed when automatic issuance fails.
func generateSelfSslCertificatePEM(domain string) (certPEM, keyPEM []byte, err error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, fmt.Errorf("generate rsa key error: %s", err)
	}
	var dnsNames []string
	if domain != "" {
		dnsNames = []string{domain}
	}
	tmpl := &x509.Certificate{
		Version:      3,
		SerialNumber: big.NewInt(time.Now().Unix()),
		Subject: pkix.Name{
			CommonName: domain,
		},
		DNSNames:              dnsNames,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().AddDate(30, 0, 0), // 30 years
	}
	cert, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, key.Public(), key)
	if err != nil {
		return nil, nil, err
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	return certPEM, keyPEM, nil
}

// writeCertificateFiles installs a certificate/key pair with an atomic replace
// (tmp file plus rename), creating the parent directories when needed.
func writeCertificateFiles(certPath, keyPath string, certPEM, keyPEM []byte) error {
	for _, target := range []struct {
		path    string
		content []byte
		mode    os.FileMode
	}{
		{certPath, certPEM, 0644},
		{keyPath, keyPEM, 0600},
	} {
		if target.path == "" {
			return fmt.Errorf("certificate file path is required")
		}
		dir := path.Dir(target.path)
		if dir != "" && dir != "." && !file.IsExist(dir) {
			err := os.MkdirAll(dir, 0755)
			if err != nil {
				return fmt.Errorf("create cert dir %s: %s", dir, err)
			}
		}
		tmp := target.path + ".tmp"
		err := os.WriteFile(tmp, target.content, target.mode)
		if err != nil {
			return fmt.Errorf("write cert %s: %s", tmp, err)
		}
		err = os.Rename(tmp, target.path)
		if err != nil {
			return fmt.Errorf("install cert %s: %s", target.path, err)
		}
	}
	return nil
}

// certFallbackRecord is the sidecar content written next to a placeholder
// certificate. It carries the reason so the operator alert can say why the node
// is serving a self-signed certificate instead of a generic warning.
type certFallbackRecord struct {
	Domain string `json:"domain"`
	At     string `json:"at"`
	Error  string `json:"error"`
}

// certFallbackRecordPath is the marker file for a fallback certificate. The
// cloud agent reads it next to the certificate path it already probes and
// reports the condition in its heartbeat, which turns it into a panel alert:
// a certificate that is self-signed on purpose must not be confused with one
// installed because issuance failed.
func certFallbackRecordPath(certFile string) string {
	return certFile + ".acme-fallback"
}

func writeCertFallbackRecord(cert *conf.CertConfig, cause error) {
	if cert.CertFile == "" {
		return
	}
	record := certFallbackRecord{
		Domain: cert.CertDomain,
		At:     time.Now().Format(time.RFC3339),
		Error:  cause.Error(),
	}
	data, err := json.Marshal(record)
	if err != nil {
		log.WithField("file", certFallbackRecordPath(cert.CertFile)).Warn(certFallbackMarker + ": marshal fallback record failed: " + err.Error())
		return
	}
	err = os.WriteFile(certFallbackRecordPath(cert.CertFile), data, 0644)
	if err != nil {
		log.WithField("file", certFallbackRecordPath(cert.CertFile)).Warn(certFallbackMarker + ": write fallback record failed: " + err.Error())
	}
}

func removeCertFallbackRecord(cert *conf.CertConfig) {
	if cert.CertFile == "" {
		return
	}
	err := os.Remove(certFallbackRecordPath(cert.CertFile))
	if err != nil && !os.IsNotExist(err) {
		log.WithField("file", certFallbackRecordPath(cert.CertFile)).Warn(certFallbackMarker + ": remove fallback record failed: " + err.Error())
	}
}

// selfSignedCertificateFile reports whether the certificate at certPath is
// self-signed, which tells a local placeholder apart from an ACME-issued
// certificate without keeping extra state next to the files.
func selfSignedCertificateFile(certPath string) bool {
	if certPath == "" {
		return false
	}
	data, err := os.ReadFile(certPath)
	if err != nil {
		return false
	}
	return isSelfSignedCertificatePEM(data)
}

// isSelfSignedCertificatePEM reports whether the first certificate in the PEM
// data is self-signed: its issuer matches its subject and it verifies against
// its own key.
func isSelfSignedCertificatePEM(data []byte) bool {
	cert, err := parseFirstCertificate(data)
	if err != nil {
		return false
	}
	if !bytes.Equal(cert.RawIssuer, cert.RawSubject) {
		return false
	}
	return cert.CheckSignature(cert.SignatureAlgorithm, cert.RawTBSCertificate, cert.Signature) == nil
}

// certificateDaysLeft reports the remaining whole days of the first
// certificate in the PEM file at certPath.
func certificateDaysLeft(certPath string) (int, bool) {
	if certPath == "" {
		return 0, false
	}
	data, err := os.ReadFile(certPath)
	if err != nil {
		return 0, false
	}
	cert, err := parseFirstCertificate(data)
	if err != nil {
		return 0, false
	}
	return int(time.Until(cert.NotAfter).Hours() / 24.0), true
}

func parseFirstCertificate(data []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("no pem block found")
	}
	return x509.ParseCertificate(block.Bytes)
}
