package node

import (
	"fmt"
	"net"
	"os"
	"path"
	"strings"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/file"
	"github.com/InazumaV/V2bX/conf"
	log "github.com/sirupsen/logrus"
)

// panelTLSMaterial carries the certificate material an SSPanel deployment may
// push at runtime. The certificate/private key payloads use the raw PEM text
// pushed by the panel; the domain is the SNI the panel expects this node to
// serve.
type panelTLSMaterial struct {
	Domain      string
	Certificate string
	PrivateKey  string
}

// certDomainFromNode returns the domain whose certificate this node should
// serve, which is the landing host of the panel "server" field (for example
// tw3.stpikit.com). The panel server_name parameter is intentionally ignored:
// for AnyTLS it carries the client-side masquerade SNI (for example
// updates.cdn-apple.com), which cannot be issued to this node.
func certDomainFromNode(node *panel.NodeInfo) string {
	if node == nil {
		return ""
	}
	if node.Common != nil {
		if domain := normalizeCertDomain(node.Common.Host); domain != "" {
			return domain
		}
	}
	if node.AnyTls != nil {
		if domain := normalizeCertDomain(node.AnyTls.Host); domain != "" {
			return domain
		}
	}
	return ""
}

// normalizeCertDomain strips a port, whitespace and a trailing dot, then
// rejects values that can never be issued a certificate (IP literals, empty
// labels, single-label hosts).
func normalizeCertDomain(raw string) string {
	domain := strings.TrimSpace(raw)
	if domain == "" {
		return ""
	}
	if host, _, err := net.SplitHostPort(domain); err == nil {
		domain = host
	}
	domain = strings.TrimSuffix(domain, ".")
	if domain == "" || net.ParseIP(domain) != nil {
		return ""
	}
	if !strings.Contains(domain, ".") {
		return ""
	}
	return strings.ToLower(domain)
}

// fillCertDefaultsForDomain derives certificate file paths when the operator
// left them empty, reusing the {domain} template that the rest of the code
// already understands.
func fillCertDefaultsForDomain(cert *conf.CertConfig, domain string) {
	if domain == "" {
		return
	}
	base := path.Join("/etc/V2bX/cert", domain)
	if cert.CertFile == "" {
		cert.CertFile = path.Join(base, "fullchain.pem")
	}
	if cert.KeyFile == "" {
		cert.KeyFile = path.Join(base, "privkey.pem")
	}
	cert.CertFile = strings.ReplaceAll(cert.CertFile, "{domain}", domain)
	cert.KeyFile = strings.ReplaceAll(cert.KeyFile, "{domain}", domain)
}

// writePushedCertificate persists panel-pushed PEM material using the same
// atomic replace strategy as the certificate tasks.
func writePushedCertificate(material panelTLSMaterial, cert *conf.CertConfig) error {
	if material.Certificate == "" || material.PrivateKey == "" {
		return fmt.Errorf("panel pushed an incomplete certificate payload")
	}
	if cert.CertFile == "" || cert.KeyFile == "" {
		return fmt.Errorf("certificate file paths are required when the panel pushes certificates")
	}
	return writeCertificateFiles(cert.CertFile, cert.KeyFile, []byte(material.Certificate), []byte(material.PrivateKey))
}

// applyPanelTLSConfig wires the panel-driven certificate chain, mirroring the
// behaviour of heki: a panel-pushed certificate payload is written to disk, and
// when only a domain is pushed the node issues and renews the certificate by
// itself. Explicit operator settings always win over the automatic mode.
func (c *Controller) applyPanelTLSConfig(node *panel.NodeInfo) error {
	if node == nil || node.Security != panel.Tls {
		return nil
	}
	cert := c.CertConfig
	if cert == nil {
		return nil
	}
	material := panelTLSMaterial{
		Domain:      certDomainFromNode(node),
		Certificate: c.panelCertificateContent(),
		PrivateKey:  c.panelPrivateKeyContent(),
	}
	if material.Certificate != "" {
		cert.PanelPush = true
	}
	if material.Domain == "" && !cert.PanelPush {
		return nil
	}
	if cert.CertMode == "none" || cert.CertMode == "" {
		if !material.HasIssuableMaterial() {
			return nil
		}
		if !cert.AutoFromPanel {
			cert.AutoFromPanel = true
			cert.CertMode = "http"
		}
	}
	if material.Domain != "" {
		if material.Domain != cert.CertDomain {
			log.WithField("tag", c.tag).
				Infof("Certificate domain from panel: %s", material.Domain)
		}
		cert.CertDomain = material.Domain
	}
	if cert.AutoFromPanel {
		fillCertDefaultsForDomain(cert, cert.CertDomain)
		if cert.Email == "" {
			cert.Email = "acme@" + cert.CertDomain
		}
	}
	if material.Certificate != "" || material.PrivateKey != "" {
		err := writePushedCertificate(material, cert)
		if err != nil {
			return err
		}
		// The pushed material replaces any placeholder, so the ACME fallback
		// marker must not outlive it: the panel alerts on that marker.
		removeCertFallbackRecord(cert)
		log.WithField("tag", c.tag).Info("Panel-pushed certificate installed")
	}
	return nil
}

// HasIssuableMaterial reports whether the panel gave either a domain or a full
// certificate payload, i.e. whether anything can be installed automatically.
func (m panelTLSMaterial) HasIssuableMaterial() bool {
	return m.Domain != "" || (m.Certificate != "" && m.PrivateKey != "")
}

// panelPushDir returns the directory holding externally written certificate
// material, defaulting to a stable location so that a panel can drop
// cert.pem / key.pem without touching the node configuration.
func (c *Controller) panelPushDir() string {
	if c.CertConfig != nil && c.CertConfig.PanelPushDir != "" {
		return c.CertConfig.PanelPushDir
	}
	return path.Join("/etc/V2bX/panel-cert")
}

// readPanelPushFile reads one file from the panel push directory. A missing
// file is not an error: it simply means the panel did not push material yet.
func (c *Controller) readPanelPushFile(name string) string {
	target := path.Join(c.panelPushDir(), name)
	if !file.IsExist(target) {
		return ""
	}
	content, err := os.ReadFile(target)
	if err != nil {
		log.WithField("tag", c.tag).Warnf("Read panel-pushed %s failed: %s", name, err)
		return ""
	}
	return string(content)
}

// panelCertificateContent resolves the certificate PEM either from the inline
// configuration or from the panel push directory.
func (c *Controller) panelCertificateContent() string {
	if c.CertConfig != nil && c.CertConfig.CertContent != "" {
		return c.CertConfig.CertContent
	}
	return c.readPanelPushFile("cert.pem")
}

// panelPrivateKeyContent resolves the private key PEM with the same precedence
// as the certificate.
func (c *Controller) panelPrivateKeyContent() string {
	if c.CertConfig != nil && c.CertConfig.KeyContent != "" {
		return c.CertConfig.KeyContent
	}
	return c.readPanelPushFile("key.pem")
}
