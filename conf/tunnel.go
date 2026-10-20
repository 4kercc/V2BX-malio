package conf

// TunnelConfig configures the native encrypted relay tunnel (compatible with
// nyanpass and soga_tunnel semantics). When enabled, V2bX accepts encrypted
// WS / TLS / WSS tunnel connections from an upstream relay on the node port
// (or a dedicatedListenPort), unwraps the AEAD frame stream and optional
// PROXY protocol v2 header, and hands the inner stream directly to the AnyTLS
// inbound with the real client source IP preserved.
type TunnelConfig struct {
	Enable        bool   `json:"Enable"`
	Type          string `json:"Type"`          // "ws" / "ws-tunnel" / "tls" / "tls-tunnel" / "wss" / "ws-tls-tunnel"
	Password      string `json:"Password"`      // shared tunnel password for HKDF-SHA256 + AES-128-GCM
	WSPath        string `json:"WSPath"`        // WebSocket path (default "/ws")
	ListenPort    uint16 `json:"ListenPort"`    // 0 = share the node's own ServerPort
	// AllowDirect: nil/true = also accept plain AnyTLS clients on this port.
	// Only honoured in "ws" mode (no outer TLS). In tls/wss modes the outer TLS is
	// always terminated here and the custom ALPN marker that used to separate
	// tunnel from direct traffic has been removed (it was a ClientHello fingerprint).
	AllowDirect   *bool `json:"AllowDirect"`
	ProxyProtocol *bool `json:"ProxyProtocol"` // nil/true = accept inner PROXY v2 header for real client IP
}

func NewTunnelConfig() *TunnelConfig {
	allowDirect := true
	proxyProto := true
	return &TunnelConfig{
		Enable:        false,
		Type:          "ws-tunnel",
		WSPath:        "/ws",
		AllowDirect:   &allowDirect,
		ProxyProtocol: &proxyProto,
	}
}

func (t *TunnelConfig) IsEnabled() bool {
	return t != nil && t.Enable && len(t.Password) > 0
}

func (t *TunnelConfig) AllowsDirect() bool {
	if t == nil || t.AllowDirect == nil {
		return true
	}
	return *t.AllowDirect
}

func (t *TunnelConfig) AcceptsProxyProtocol() bool {
	if t == nil || t.ProxyProtocol == nil {
		return true
	}
	return *t.ProxyProtocol
}
