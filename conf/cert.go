package conf

type CertConfig struct {
	CertMode         string            `json:"CertMode"` // none, file, self, http, dns
	RejectUnknownSni bool              `json:"RejectUnknownSni"`
	CertDomain       string            `json:"CertDomain"`
	CertFile         string            `json:"CertFile"`
	KeyFile          string            `json:"KeyFile"`
	Provider         string            `json:"Provider"` // alidns, cloudflare, gandi, godaddy....
	Email            string            `json:"Email"`
	DNSEnv           map[string]string `json:"DNSEnv"`
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
}

func NewCertConfig() *CertConfig {
	return &CertConfig{
		CertMode: "none",
	}
}
