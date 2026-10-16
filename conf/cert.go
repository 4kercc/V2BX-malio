package conf

import "strings"

type CertConfig struct {
	CertMode         string            `json:"CertMode"` // none, file, self, http, dns
	RejectUnknownSni bool              `json:"RejectUnknownSni"`
	CertDomain       string            `json:"CertDomain"`
	// CertDomains issues one certificate covering several names (a single ACME
	// order with all of them as SANs). "auto" resolves to the domains configured
	// on this machine's nodes, so a machine with five landing domains signs one
	// certificate instead of five. CertDomain stays the single-name form and is
	// used as the inbound TLS server name.
	CertDomains []string `json:"CertDomains"`
	// KeyType selects the certificate key algorithm and size: ec-256, ec-384,
	// rsa2048 (default), rsa4096.
	KeyType  string            `json:"KeyType"`
	CertFile string            `json:"CertFile"`
	KeyFile  string            `json:"KeyFile"`
	Provider string            `json:"Provider"` // alidns, cloudflare, gandi, godaddy....
	Email    string            `json:"Email"`
	DNSEnv   map[string]string `json:"DNSEnv"`
	// ECHKey is the inbound ECH key set (Base64 ECHConfigList), aligned with
	// sing-box tls.ech.key. Enabling ECH also requires ECHServerName, which
	// encodes the public_name into the config list at run time.
	ECHKey        string `json:"ECHKey"`
	ECHServerName string `json:"ECHServerName"`
	// ACMEDataDirectory overrides the sing-box ACME storage location. It is
	// only used when CertMode is http/dns and the build carries with_acme.
	ACMEDataDirectory string `json:"ACMEDataDirectory"`
	// AutoFromPanel records that CertMode was filled in by the panel-driven
	// certificate chain instead of an explicit local choice. Auto configuration
	// must never override a mode the operator set by hand.
	AutoFromPanel bool `json:"AutoFromPanel"`
	// StrictACMEFailure keeps the historic behaviour of refusing to start the
	// node when automatic issuance (http/dns) fails. When it is false, which is
	// the default, a failed issuance installs a self-signed certificate for
	// CertDomain instead so the node still serves traffic, and the failure is
	// reported with a CERT-FALLBACK warning. Availability wins by default: a
	// node that cannot start serves nobody, while a self-signed certificate
	// only affects clients that verify the chain.
	StrictACMEFailure bool `json:"StrictACMEFailure"`
	// PanelPush records that the current certificate files were written from a
	// panel-pushed certificate payload. Manual issuance is skipped while the
	// material keeps arriving from the panel.
	PanelPush bool `json:"PanelPush"`
	// CertContent / KeyContent accept an inline PEM payload for the node, which
	// is how a panel-pushed or externally managed certificate reaches the node
	// without a file copy step.
	CertContent string `json:"CertContent"`
	KeyContent  string `json:"KeyContent"`
	// PanelPushDir is a directory holding panel-written cert.pem / key.pem. It
	// is meant for multi-instance nodes that share one certificate directory.
	PanelPushDir string `json:"PanelPushDir"`
	// InheritFromMachine marks a node whose certificate settings were filled in
	// from the machine-level "Cert" block: such a node never issues or renews on
	// its own, the machine certificate owner does it once for all of them.
	InheritFromMachine bool `json:"-"`
	// CertOwner marks the single node responsible for issuing and renewing the
	// machine certificate (the first node that inherits it).
	CertOwner bool `json:"-"`
}

func NewCertConfig() *CertConfig {
	return &CertConfig{
		CertMode: "none",
	}
}

// DomainsOf returns the certificate names to issue, in order, with the "auto"
// placeholder resolved by the caller. CertDomain is the fallback for the
// single-name form so existing configurations keep working unchanged.
func (c *CertConfig) DomainsOf() []string {
	var out []string
	for _, d := range c.CertDomains {
		if strings.TrimSpace(d) != "" {
			out = append(out, strings.TrimSpace(d))
		}
	}
	if len(out) == 0 && c.CertDomain != "" {
		out = append(out, c.CertDomain)
	}
	return out
}

// HasAutoDomain reports whether the domain list needs to be resolved from the
// machine's node configurations.
func (c *CertConfig) HasAutoDomain() bool {
	for _, d := range c.CertDomains {
		if strings.EqualFold(strings.TrimSpace(d), "auto") {
			return true
		}
	}
	return false
}

// MergeCertConfig returns the certificate configuration a node should use: the
// machine-level certificate supplies defaults for everything the node does not
// set itself, so a machine signs one certificate for all of its nodes while any
// explicit per-node value still wins.
func MergeCertConfig(machine, node *CertConfig) *CertConfig {
	if machine == nil {
		return node
	}
	if node == nil {
		node = NewCertConfig()
	}
	merged := *node
	merged.InheritFromMachine = true

	if merged.CertMode == "" || merged.CertMode == "none" {
		if machine.CertMode != "" && machine.CertMode != "none" {
			merged.CertMode = machine.CertMode
		}
	}
	if merged.CertDomain == "" {
		merged.CertDomain = machine.CertDomain
	}
	if len(merged.CertDomains) == 0 {
		merged.CertDomains = machine.CertDomains
	}
	if merged.KeyType == "" {
		merged.KeyType = machine.KeyType
	}
	if merged.CertFile == "" {
		merged.CertFile = machine.CertFile
	}
	if merged.KeyFile == "" {
		merged.KeyFile = machine.KeyFile
	}
	if merged.Provider == "" {
		merged.Provider = machine.Provider
	}
	if merged.Email == "" {
		merged.Email = machine.Email
	}
	if len(merged.DNSEnv) == 0 {
		merged.DNSEnv = machine.DNSEnv
	}
	if merged.ECHKey == "" {
		merged.ECHKey = machine.ECHKey
	}
	if merged.ECHServerName == "" {
		merged.ECHServerName = machine.ECHServerName
	}
	if merged.ACMEDataDirectory == "" {
		merged.ACMEDataDirectory = machine.ACMEDataDirectory
	}
	// Bools cannot express "unset": a machine-level yes is inherited, an explicit
	// per-node yes is kept.
	merged.RejectUnknownSni = merged.RejectUnknownSni || machine.RejectUnknownSni
	merged.StrictACMEFailure = merged.StrictACMEFailure || machine.StrictACMEFailure

	return &merged
}
