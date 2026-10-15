package sing

import (
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"net"
	"net/netip"
	"strings"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

// This build is trimmed to AnyTLS only (sing-box core).

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

// buildInboundTLS assembles the inbound TLS options for an AnyTLS node from the
// panel node info and local CertConfig. The certificate domain, not the panel
// server_name masquerade value, drives the inbound TLS server name.
func buildInboundTLS(info *panel.NodeInfo, c *conf.Options) (option.InboundTLSOptions, error) {
	var tls option.InboundTLSOptions
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
	listen := option.ListenOptions{
		Listen:      (*badoption.Addr)(&addr),
		ListenPort:  uint16(info.Common.ServerPort),
		TCPFastOpen: c.SingOptions.TCPFastOpen,
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
	default:
		return option.Inbound{}, fmt.Errorf("unsupported node type: %s (this build supports anytls only)", info.Type)
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
	return nil
}

func (b *Sing) AddNode(tag string, info *panel.NodeInfo, config *conf.Options) error {
	err := b.createInbound(tag, info, config, config.ListenIP)
	if err != nil {
		return err
	}
	if config.ListenIP6 == "" {
		return nil
	}
	// Optional IPv6 ingress: the same node, users and certificate, reached on a
	// second address. Its connections are folded back into this node's tag by
	// the hook, and the auto-generated SendIP route treats both tags the same.
	secondary := secondaryInboundTag(tag)
	err = b.createInbound(secondary, info, config, config.ListenIP6)
	if err != nil {
		// Roll the primary listener back: a half-registered node would report
		// traffic from an inbound without limits or users.
		_ = b.box.Inbound().Remove(tag)
		return fmt.Errorf("add ipv6 inbound error: %s", err)
	}
	b.hookServer.LinkSecondaryInbound(tag, secondary)
	log.Info(fmt.Sprintf("Node %s also accepts IPv6 clients on %s:%d", tag, config.ListenIP6, info.Common.ServerPort))
	return nil
}

func (b *Sing) DelNode(tag string) error {
	in := b.box.Inbound()
	secondary := secondaryInboundTag(tag)
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
