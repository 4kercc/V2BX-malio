package sing

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	"github.com/goccy/go-json"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

// buildECHKeyPEM normalizes an ECH key set into the PEM block sing-box expects
// for inbound ECH (label "ECH KEYS"). Accepts either a complete PEM (passed
// through) or a bare Base64 ECHConfigList as pushed by the panel.
func buildECHKeyPEM(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", nil
	}
	if strings.Contains(trimmed, "-----BEGIN") {
		block, rest := pem.Decode([]byte(trimmed))
		if block == nil || block.Type != "ECH KEYS" || len(strings.TrimSpace(string(rest))) > 0 {
			return "", fmt.Errorf("invalid ECH keys pem, expecting a single \"ECH KEYS\" block")
		}
		return trimmed, nil
	}
	keySet, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil {
		return "", fmt.Errorf("decode ECH key base64: %w", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "ECH KEYS", Bytes: keySet})), nil
}

// certificateDomainFromNode resolves the domain whose certificate the node is
// expected to serve. The panel "server" host (CommonNode.Host) is the landing
// domain the operator controls, so it is the certificate identity. The panel
// server_name parameter is deliberately NOT used here: for AnyTLS it carries
// the client-side masquerade SNI (for example updates.cdn-apple.com), which is
// not a domain this node can obtain a certificate for.
func certificateDomainFromNode(info *panel.NodeInfo) string {
	if info == nil {
		return ""
	}
	if info.Common != nil {
		if domain := normalizeDomainValue(info.Common.Host); domain != "" {
			return domain
		}
	}
	if info.AnyTls != nil {
		if domain := normalizeDomainValue(info.AnyTls.Host); domain != "" {
			return domain
		}
	}
	return ""
}

// normalizeDomainValue lower-cases a host value and rejects values that cannot
// be a certificate name, such as IP literals.
func normalizeDomainValue(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return ""
	}
	if host, _, err := net.SplitHostPort(value); err == nil {
		value = host
	}
	value = strings.TrimSuffix(value, ".")
	if value == "" || net.ParseIP(value) != nil {
		return ""
	}
	if !strings.Contains(value, ".") {
		return ""
	}
	return strings.ToLower(value)
}

type HttpNetworkConfig struct {
	Header struct {
		Type     string           `json:"type"`
		Request  *json.RawMessage `json:"request"`
		Response *json.RawMessage `json:"response"`
	} `json:"header"`
}

type HttpRequest struct {
	Version string   `json:"version"`
	Method  string   `json:"method"`
	Path    []string `json:"path"`
	Headers struct {
		Host []string `json:"Host"`
	} `json:"headers"`
}

type WsNetworkConfig struct {
	Path    string            `json:"path"`
	Headers map[string]string `json:"headers"`
}

type GrpcNetworkConfig struct {
	ServiceName string `json:"serviceName"`
}

type HttpupgradeNetworkConfig struct {
	Path string `json:"path"`
	Host string `json:"host"`
}

// buildInboundTLS assembles the inbound TLS options for a node.
//   - VLESS-Reality nodes build the sing-box Reality options from the panel
//     TlsSettings/RealityConfig; no certificate is needed.
//   - AnyTLS nodes use the panel certificate chain handled by the local cert
//     machine below; the certificate domain, not the panel server_name
//     masquerade value, drives the inbound TLS server name.
func buildInboundTLS(info *panel.NodeInfo, c *conf.Options) (option.InboundTLSOptions, error) {
	var tls option.InboundTLSOptions
	if info.Security == panel.Reality {
		v := info.VAllss
		if v == nil {
			return tls, fmt.Errorf("reality node is missing VLESS config")
		}
		tls.Enabled = true
		tls.ServerName = v.TlsSettings.ServerName
		port, _ := strconv.Atoi(v.TlsSettings.ServerPort)
		dest := v.TlsSettings.Dest
		if dest == "" {
			dest = tls.ServerName
		}
		mtd, _ := time.ParseDuration(v.RealityConfig.MaxTimeDiff)
		tls.Reality = &option.InboundRealityOptions{
			Enabled:    true,
			ShortID:    []string{v.TlsSettings.ShortId},
			PrivateKey: v.TlsSettings.PrivateKey,
			Xver:       uint8(v.TlsSettings.Xver),
			Handshake: option.InboundRealityHandshakeOptions{
				ServerOptions: option.ServerOptions{
					Server:     dest,
					ServerPort: uint16(port),
				},
			},
			MaxTimeDifference: badoption.Duration(mtd),
		}
		return tls, nil
	}
	if info.Security != panel.Tls {
		return tls, nil
	}
	if c.CertConfig == nil {
		return tls, fmt.Errorf("the CertConfig is not vail")
	}
	cc := c.CertConfig
	// Prefer the certificate the operator configured, then the landing domain
	// reported by the panel.
	certDomain := cc.CertDomain
	if certDomain == "" {
		certDomain = certificateDomainFromNode(info)
	}
	switch cc.CertMode {
	case "none", "":
		// TLS explicitly disabled by configuration.
	default:
		tls.Enabled = true
		tls.ServerName = certDomain
		tls.CertificatePath = cc.CertFile
		tls.KeyPath = cc.KeyFile
	}
	if cc.ECHKey != "" {
		if !tls.Enabled {
			return tls, fmt.Errorf("ech requires tls to be enabled (cert_mode=%q)", cc.CertMode)
		}
		echPEM, err := buildECHKeyPEM(cc.ECHKey)
		if err != nil {
			return tls, err
		}
		tls.ECH = &option.InboundECHOptions{
			Enabled: true,
			Key:     badoption.Listable[string]{echPEM},
		}
	}
	return tls, nil
}

// secondaryInboundSuffix marks the extra inbound that accepts a node's IPv6
// clients. Traffic arriving there is attributed to the primary tag, so limits,
// device counting and traffic reports stay per node. A node whose own name ends
// with this suffix cannot be combined with an IPv6 ingress: the tags would
// collide and AddNode fails loudly instead of misattributing traffic.
const secondaryInboundSuffix = "_v6"

// secondaryInboundTag returns the tag of the extra IPv6 ingress of a node.
func secondaryInboundTag(tag string) string {
	return tag + secondaryInboundSuffix
}

func getInboundOptions(tag string, info *panel.NodeInfo, c *conf.Options) (option.Inbound, error) {
	return getInboundOptionsForListen(tag, info, c, c.ListenIP)
}

// getInboundOptionsForListen builds the inbound for one listen address of a
// node. The address is written as a bare IP (0.0.0.0, ::, 2401:db8::1): sing-box
// turns 0.0.0.0 into a tcp4 socket, while :: yields a dual stack one.
func getInboundOptionsForListen(tag string, info *panel.NodeInfo, c *conf.Options, listenIP string) (option.Inbound, error) {
	addr, err := netip.ParseAddr(listenIP)
	if err != nil {
		return option.Inbound{}, fmt.Errorf("the listen ip not vail: %s", listenIP)
	}
	listenPort := uint16(info.Common.ServerPort)
	// When the native tunnel shares the node's own ServerPort, TunnelServer owns
	// the public socket and hands unwrapped connections directly to NewConnectionEx,
	// so sing-box's internal listener binds an ephemeral loopback port.
	if c.TunnelConfig != nil && c.TunnelConfig.IsEnabled() {
		tPort := c.TunnelConfig.ListenPort
		if tPort == 0 || tPort == listenPort {
			addr = netip.MustParseAddr("127.0.0.1")
			listenPort = 0
		}
	}
	listen := option.ListenOptions{
		Listen:      (*badoption.Addr)(&addr),
		ListenPort:  listenPort,
		TCPFastOpen: c.SingOptions.TCPFastOpen,
	}
	var multiplex *option.InboundMultiplexOptions
	if c.SingOptions.Multiplex != nil {
		multiplexOption := option.InboundMultiplexOptions{
			Enabled: c.SingOptions.Multiplex.Enabled,
			Padding: c.SingOptions.Multiplex.Padding,
			Brutal: &option.BrutalOptions{
				Enabled:  c.SingOptions.Multiplex.Brutal.Enabled,
				UpMbps:   c.SingOptions.Multiplex.Brutal.UpMbps,
				DownMbps: c.SingOptions.Multiplex.Brutal.DownMbps,
			},
		}
		multiplex = &multiplexOption
	}
	tls, err := buildInboundTLS(info, c)
	if err != nil {
		return option.Inbound{}, err
	}
	in := option.Inbound{
		Tag: tag,
	}
	switch info.Type {
	case "anytls":
		in.Type = "anytls"
		in.Options = &option.AnyTLSInboundOptions{
			ListenOptions: listen,
			PaddingScheme: info.AnyTls.PaddingScheme,
			InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{
				TLS: &tls,
			},
		}
	case "vmess", "vless":
		n := info.VAllss
		t := option.V2RayTransportOptions{
			Type: n.Network,
		}
		switch n.Network {
		case "tcp":
			if len(n.NetworkSettings) != 0 {
				network := HttpNetworkConfig{}
				err := json.Unmarshal(n.NetworkSettings, &network)
				if err != nil {
					return option.Inbound{}, fmt.Errorf("decode NetworkSettings error: %s", err)
				}
				//Todo fix http options
				if network.Header.Type == "http" {
					t.Type = network.Header.Type
					var request HttpRequest
					if network.Header.Request != nil {
						err = json.Unmarshal(*network.Header.Request, &request)
						if err != nil {
							return option.Inbound{}, fmt.Errorf("decode HttpRequest error: %s", err)
						}
						t.HTTPOptions.Host = request.Headers.Host
						t.HTTPOptions.Path = request.Path[0]
						t.HTTPOptions.Method = request.Method
					}
				} else {
					t.Type = ""
				}
			} else {
				t.Type = ""
			}
		case "ws":
			var (
				path    string
				ed      int
				headers map[string]badoption.Listable[string]
			)
			if len(n.NetworkSettings) != 0 {
				network := WsNetworkConfig{}
				err := json.Unmarshal(n.NetworkSettings, &network)
				if err != nil {
					return option.Inbound{}, fmt.Errorf("decode NetworkSettings error: %s", err)
				}
				var u *url.URL
				u, err = url.Parse(network.Path)
				if err != nil {
					return option.Inbound{}, fmt.Errorf("parse path error: %s", err)
				}
				path = u.Path
				ed, _ = strconv.Atoi(u.Query().Get("ed"))
				headers = make(map[string]badoption.Listable[string], len(network.Headers))
				for k, v := range network.Headers {
					headers[k] = badoption.Listable[string]{
						v,
					}
				}
			}
			t.WebsocketOptions = option.V2RayWebsocketOptions{
				Path:                path,
				EarlyDataHeaderName: "Sec-WebSocket-Protocol",
				MaxEarlyData:        uint32(ed),
				Headers:             headers,
			}
		case "grpc":
			network := GrpcNetworkConfig{}
			if len(n.NetworkSettings) != 0 {
				err := json.Unmarshal(n.NetworkSettings, &network)
				if err != nil {
					return option.Inbound{}, fmt.Errorf("decode NetworkSettings error: %s", err)
				}
			}
			t.GRPCOptions = option.V2RayGRPCOptions{
				ServiceName: network.ServiceName,
			}
		case "httpupgrade":
			network := HttpupgradeNetworkConfig{}
			if len(n.NetworkSettings) != 0 {
				err := json.Unmarshal(n.NetworkSettings, &network)
				if err != nil {
					return option.Inbound{}, fmt.Errorf("decode NetworkSettings error: %s", err)
				}
			}
			t.HTTPUpgradeOptions = option.V2RayHTTPUpgradeOptions{
				Path: network.Path,
				Host: network.Host,
			}
		}
		if info.Type == "vless" {
			in.Type = "vless"
			in.Options = &option.VLESSInboundOptions{
				ListenOptions: listen,
				InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{
					TLS: &tls,
				},
				Transport: &t,
				Multiplex: multiplex,
			}
		} else {
			in.Type = "vmess"
			in.Options = &option.VMessInboundOptions{
				ListenOptions: listen,
				InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{
					TLS: &tls,
				},
				Transport: &t,
				Multiplex: multiplex,
			}
		}
	case "shadowsocks":
		in.Type = "shadowsocks"
		n := info.Shadowsocks
		var keyLength int
		switch n.Cipher {
		case "2022-blake3-aes-128-gcm":
			keyLength = 16
		case "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305":
			keyLength = 32
		default:
			keyLength = 16
		}
		ssoption := &option.ShadowsocksInboundOptions{
			ListenOptions: listen,
			Method:        n.Cipher,
			Multiplex:     multiplex,
		}
		p := make([]byte, keyLength)
		_, _ = rand.Read(p)
		randomPasswd := string(p)
		if strings.Contains(n.Cipher, "2022") {
			ssoption.Password = n.ServerKey
			randomPasswd = base64.StdEncoding.EncodeToString([]byte(randomPasswd))
		}
		ssoption.Users = []option.ShadowsocksUser{{
			Password: randomPasswd,
		}}
		in.Options = ssoption
	case "trojan":
		n := info.Trojan
		t := option.V2RayTransportOptions{
			Type: n.Network,
		}
		switch n.Network {
		case "tcp":
			t.Type = ""
		case "ws":
			var (
				path    string
				ed      int
				headers map[string]badoption.Listable[string]
			)
			if len(n.NetworkSettings) != 0 {
				network := WsNetworkConfig{}
				err := json.Unmarshal(n.NetworkSettings, &network)
				if err != nil {
					return option.Inbound{}, fmt.Errorf("decode NetworkSettings error: %s", err)
				}
				var u *url.URL
				u, err = url.Parse(network.Path)
				if err != nil {
					return option.Inbound{}, fmt.Errorf("parse path error: %s", err)
				}
				path = u.Path
				ed, _ = strconv.Atoi(u.Query().Get("ed"))
				headers = make(map[string]badoption.Listable[string], len(network.Headers))
				for k, v := range network.Headers {
					headers[k] = badoption.Listable[string]{
						v,
					}
				}
			}
			t.WebsocketOptions = option.V2RayWebsocketOptions{
				Path:                path,
				EarlyDataHeaderName: "Sec-WebSocket-Protocol",
				MaxEarlyData:        uint32(ed),
				Headers:             headers,
			}
		case "grpc":
			network := GrpcNetworkConfig{}
			if len(n.NetworkSettings) != 0 {
				err := json.Unmarshal(n.NetworkSettings, &network)
				if err != nil {
					return option.Inbound{}, fmt.Errorf("decode NetworkSettings error: %s", err)
				}
			}
			t.GRPCOptions = option.V2RayGRPCOptions{
				ServiceName: network.ServiceName,
			}
		default:
			t.Type = ""
		}
		in.Type = "trojan"
		trojanoption := &option.TrojanInboundOptions{
			ListenOptions: listen,
			InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{
				TLS: &tls,
			},
			Transport: &t,
			Multiplex: multiplex,
		}
		if c.SingOptions.FallBackConfigs != nil {
			// fallback handling
			fallback := c.SingOptions.FallBackConfigs.FallBack
			fallbackPort, err := strconv.Atoi(fallback.ServerPort)
			if err == nil {
				trojanoption.Fallback = &option.ServerOptions{
					Server:     fallback.Server,
					ServerPort: uint16(fallbackPort),
				}
			}
			fallbackForALPNMap := c.SingOptions.FallBackConfigs.FallBackForALPN
			fallbackForALPN := make(map[string]*option.ServerOptions, len(fallbackForALPNMap))
			if err := processFallback(c, fallbackForALPN); err == nil {
				trojanoption.FallbackForALPN = fallbackForALPN
			}
		}
		in.Options = trojanoption
	case "tuic":
		in.Type = "tuic"
		tls.ALPN = append(tls.ALPN, "h3")
		in.Options = &option.TUICInboundOptions{
			ListenOptions:     listen,
			CongestionControl: info.Tuic.CongestionControl,
			ZeroRTTHandshake:  info.Tuic.ZeroRTTHandshake,
			InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{
				TLS: &tls,
			},
		}
	case "hysteria":
		in.Type = "hysteria"
		in.Options = &option.HysteriaInboundOptions{
			ListenOptions: listen,
			UpMbps:        info.Hysteria.UpMbps,
			DownMbps:      info.Hysteria.DownMbps,
			Obfs:          info.Hysteria.Obfs,
			InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{
				TLS: &tls,
			},
		}
	case "hysteria2":
		in.Type = "hysteria2"
		var obfs *option.Hysteria2Obfs
		if info.Hysteria2.ObfsType != "" && info.Hysteria2.ObfsPassword != "" {
			obfs = &option.Hysteria2Obfs{
				Type:     info.Hysteria2.ObfsType,
				Password: info.Hysteria2.ObfsPassword,
			}
		} else if info.Hysteria2.ObfsType != "" {
			obfs = &option.Hysteria2Obfs{
				Type:     "salamander",
				Password: info.Hysteria2.ObfsType,
			}
		}
		in.Options = &option.Hysteria2InboundOptions{
			ListenOptions:         listen,
			UpMbps:                info.Hysteria2.UpMbps,
			DownMbps:              info.Hysteria2.DownMbps,
			IgnoreClientBandwidth: info.Hysteria2.Ignore_Client_Bandwidth,
			Obfs:                  obfs,
			InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{
				TLS: &tls,
			},
		}
	default:
		return option.Inbound{}, fmt.Errorf("unsupported node type: %s (supported: anytls/vless/vmess/trojan/shadowsocks/tuic/hysteria/hysteria2)", info.Type)
	}
	return in, nil
}

// createInbound registers one listen address of a node with the box.
func (b *Sing) createInbound(tag string, info *panel.NodeInfo, config *conf.Options, listenIP string) error {
	c, err := getInboundOptionsForListen(tag, info, config, listenIP)
	if err != nil {
		return err
	}
	err = b.box.Inbound().Create(
		b.ctx,
		b.box.Router(),
		b.logFactory.NewLogger(fmt.Sprintf("inbound/%s[%s]", c.Type, tag)),
		tag,
		c.Type,
		c.Options,
	)
	if err != nil {
		return fmt.Errorf("add inbound error: %s", err)
	}
	if config.TunnelConfig != nil && config.TunnelConfig.IsEnabled() {
		inb, found := b.box.Inbound().Get(tag)
		if !found {
			return fmt.Errorf("inbound %s not found after create", tag)
		}
		connHandler, ok := inb.(adapter.ConnectionHandlerEx)
		if !ok {
			_ = b.box.Inbound().Remove(tag)
			return fmt.Errorf("inbound %s does not implement ConnectionHandlerEx", tag)
		}
		tPort := config.TunnelConfig.ListenPort
		if tPort == 0 {
			tPort = uint16(info.Common.ServerPort)
		}
		ts, err := newTunnelServer(b.ctx, tag, listenIP, tPort, config.TunnelConfig, config.CertConfig, connHandler)
		if err != nil {
			_ = b.box.Inbound().Remove(tag)
			return fmt.Errorf("start tunnel server on %s:%d error: %s", listenIP, tPort, err)
		}
		if old, loaded := b.tunnels.LoadAndDelete(tag); loaded {
			_ = old.(*TunnelServer).Close()
		}
		b.tunnels.Store(tag, ts)
		log.Info(fmt.Sprintf("Node %s: V2bX encrypted tunnel (%s, path=%s, allow_direct=%v) listening on %s:%d",
			tag, normalizeTunnelMode(config.TunnelConfig.Type), normalizeTunnelPath(config.TunnelConfig.WSPath),
			config.TunnelConfig.AllowsDirect(), listenIP, tPort))
	}
	return nil
}

// planListeners decides which listen addresses a node really gets. An IPv6
// wildcard covers IPv4 as well (dual stack), so combining it with a wider
// address would only make the two sockets fight over the same port:
//
//	0.0.0.0 + ::  -> a single dual-stack :: listener (same coverage, no conflict)
//	::      + ip  -> the wildcard already covers it, the extra address is dropped
//
// Everything else (a specific IPv4 plus a specific IPv6, which is how one machine
// serves several nodes) is left untouched.
func planListeners(listenIP, listenIP6 string) (primary, secondary, note string) {
	if listenIP6 == "" {
		return listenIP, "", ""
	}
	primaryAddr, err := netip.ParseAddr(listenIP)
	if err != nil {
		return listenIP, listenIP6, ""
	}
	secondaryAddr, err := netip.ParseAddr(listenIP6)
	if err != nil {
		return listenIP, listenIP6, ""
	}
	if primaryAddr == netip.IPv4Unspecified() && secondaryAddr == netip.IPv6Unspecified() {
		// Both are wildcards: the dual-stack listener covers what the IPv4 one
		// covered, so a single socket serves both families.
		return listenIP6, "", fmt.Sprintf("%s is a dual-stack listener and already accepts IPv4 clients", listenIP6)
	}
	if primaryAddr == netip.IPv6Unspecified() {
		return listenIP, "", fmt.Sprintf("%s already accepts IPv4 and IPv6 clients", listenIP)
	}
	// A specific IPv4 plus "::" is deliberately not collapsed: the wildcard is
	// machine-wide and would take over the addresses of the other nodes on this
	// host, so it is tried as a second listener and its bind fails instead.
	return listenIP, listenIP6, ""
}

// resolveListenIP6 turns ListenIP6="auto" into a free global IPv6 address of
// this machine. The assignment is remembered per node tag so a reload never
// moves the address (AAAA records stay valid), and addresses that other nodes
// configure explicitly are never taken.
func (b *Sing) resolveListenIP6(tag string, config *conf.Options) string {
	if !strings.EqualFold(strings.TrimSpace(config.ListenIP6), "auto") {
		return config.ListenIP6
	}
	b.v6Mu.Lock()
	defer b.v6Mu.Unlock()

	taken := b.takenV6Addresses(tag)
	if assigned, ok := b.v6Assign.Load(tag); ok {
		addr := assigned.(string)
		if !taken[addr] && isLocalGlobalIPv6(addr) {
			return addr
		}
	}
	if addr := pickFreeV6(localGlobalIPv6Addrs(), taken); addr != "" {
		b.v6Assign.Store(tag, addr)
		log.Info(fmt.Sprintf("Node %s: ListenIP6=auto -> %s", tag, addr))
		return addr
	}
	log.Error(fmt.Sprintf("Node %s: ListenIP6=auto 但本机没有空闲的公网 IPv6 地址，v6 入口已跳过", tag))
	return ""
}

// pickFreeV6 returns the first address nobody has claimed yet, taking both lists
// in their stable (sorted) order so repeated runs make the same choice.
func pickFreeV6(local []string, taken map[string]bool) string {
	for _, addr := range local {
		if !taken[addr] {
			return addr
		}
	}
	return ""
}

// takenV6Addresses lists the IPv6 addresses already spoken for: configured
// explicitly by other nodes, or handed to them by "auto".
func (b *Sing) takenV6Addresses(selfTag string) map[string]bool {
	taken := map[string]bool{}
	for _, nc := range b.nodesConfig {
		name := nc.Options.Name
		if name == "" {
			name = "node_" + strconv.Itoa(nc.ApiConfig.NodeID)
		}
		if name == selfTag {
			continue
		}
		addr := strings.TrimSpace(nc.Options.ListenIP6)
		if addr != "" && !strings.EqualFold(addr, "auto") {
			taken[addr] = true
		}
	}
	b.v6Assign.Range(func(key, value any) bool {
		if key.(string) != selfTag {
			taken[value.(string)] = true
		}
		return true
	})
	return taken
}

// localGlobalIPv6Addrs returns this machine's global IPv6 addresses in a stable
// order, which keeps "auto" assignments reproducible across restarts.
func localGlobalIPv6Addrs() []string {
	list, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	var out []string
	for _, a := range list {
		ipNet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip := ipNet.IP
		if ip.To4() != nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() || ip.IsPrivate() {
			continue
		}
		out = append(out, ip.String())
	}
	sort.Strings(out)
	return out
}

func isLocalGlobalIPv6(addr string) bool {
	for _, a := range localGlobalIPv6Addrs() {
		if a == addr {
			return true
		}
	}
	return false
}

func (b *Sing) AddNode(tag string, info *panel.NodeInfo, config *conf.Options) error {
	if config.TunnelConfig != nil && config.TunnelConfig.Enable && len(config.TunnelConfig.Password) == 0 {
		log.Warn(fmt.Sprintf("Node %s: TunnelConfig.Enable is true but TunnelConfig.Password is empty; the encrypted tunnel is disabled", tag))
	}
	listenIP6 := b.resolveListenIP6(tag, config)
	primary, secondary, note := planListeners(config.ListenIP, listenIP6)
	if note != "" {
		log.Info(fmt.Sprintf("Node %s: extra listen address %s skipped: %s", tag, listenIP6, note))
	}
	err := b.createInbound(tag, info, config, primary)
	if err != nil {
		return err
	}
	if secondary == "" {
		return nil
	}
	// Optional IPv6 ingress: the same node, users and certificate, reached on a
	// second address. Its connections are folded back into this node's tag by
	// the hook, and the auto-generated SendIP route treats both tags the same.
	secondaryTag := secondaryInboundTag(tag)
	err = b.createInbound(secondaryTag, info, config, secondary)
	if err != nil {
		// The node keeps serving on its primary address: a bad extra address
		// (not local, already taken, IPv6 wildcard next to a specific IPv4) must
		// not take a working node down.
		log.Error(fmt.Sprintf("Node %s: IPv6 ingress on %s failed, node keeps serving on %s: %s",
			tag, secondary, primary, err))
		return nil
	}
	b.hookServer.LinkSecondaryInbound(tag, secondaryTag)
	log.Info(fmt.Sprintf("Node %s also accepts IPv6 clients on %s:%d", tag, secondary, info.Common.ServerPort))
	return nil
}

func (b *Sing) DelNode(tag string) error {
	in := b.box.Inbound()
	secondary := secondaryInboundTag(tag)
	if old, loaded := b.tunnels.LoadAndDelete(secondary); loaded {
		_ = old.(*TunnelServer).Close()
	}
	if old, loaded := b.tunnels.LoadAndDelete(tag); loaded {
		_ = old.(*TunnelServer).Close()
	}
	if _, found := in.Get(secondary); found {
		err := in.Remove(secondary)
		if err != nil {
			return fmt.Errorf("delete ipv6 inbound error: %s", err)
		}
		b.hookServer.UnlinkSecondaryInbound(secondary)
	}
	err := in.Remove(tag)
	if err != nil {
		return fmt.Errorf("delete inbound error: %s", err)
	}
	// Note: the tag's TrafficCounter is intentionally kept across node reloads
	// so traffic accumulated around the reload window is still reported.
	return nil
}
