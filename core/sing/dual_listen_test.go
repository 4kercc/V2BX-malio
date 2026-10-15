package sing

import (
	"net/netip"
	"testing"

	"github.com/InazumaV/V2bX/conf"
	"github.com/sagernet/sing-box/option"
)

func dualListenOptions(listenIP, listenIP6 string) *conf.Options {
	opts := anytlsOptions(&conf.CertConfig{
		CertMode:   "self",
		CertDomain: "hytron1.wukong.us.kg",
		CertFile:   "/etc/ssl/hytron1.wukong.us.kg.crt",
		KeyFile:    "/etc/ssl/hytron1.wukong.us.kg.key",
	})
	opts.ListenIP = listenIP
	opts.ListenIP6 = listenIP6
	return opts
}

func anytlsListenOptions(t *testing.T, in option.Inbound) option.ListenOptions {
	t.Helper()
	opts, ok := in.Options.(*option.AnyTLSInboundOptions)
	if !ok {
		t.Fatalf("expected anytls inbound options, got %T", in.Options)
	}
	return opts.ListenOptions
}

func TestIPv6IngressUsesItsOwnListenAddress(t *testing.T) {
	opts := dualListenOptions("45.196.221.58", "2401:b60:3d:2::2")
	info := anytlsNodeInfo("hytron1.wukong.us.kg", "updates.cdn-apple.com")

	primary, err := getInboundOptions("node_37", info, opts)
	if err != nil {
		t.Fatalf("primary inbound: %v", err)
	}
	primaryListen := anytlsListenOptions(t, primary)
	if got := netip.Addr(*primaryListen.Listen); got != netip.MustParseAddr("45.196.221.58") {
		t.Fatalf("primary inbound must keep the configured IPv4 listen, got %s", got)
	}

	secondary, err := getInboundOptionsForListen(secondaryInboundTag("node_37"), info, opts, opts.ListenIP6)
	if err != nil {
		t.Fatalf("ipv6 inbound: %v", err)
	}
	if secondary.Tag != "node_37_v6" {
		t.Fatalf("secondary inbound tag mismatch: %q", secondary.Tag)
	}
	secondaryListen := anytlsListenOptions(t, secondary)
	if got := netip.Addr(*secondaryListen.Listen); got != netip.MustParseAddr("2401:b60:3d:2::2") {
		t.Fatalf("ipv6 inbound must listen on the extra address, got %s", got)
	}
	// Same node identity: same port, same certificate, same SNI handling.
	if secondaryListen.ListenPort != primaryListen.ListenPort {
		t.Fatalf("both ingresses must use the node port: %d vs %d", secondaryListen.ListenPort, primaryListen.ListenPort)
	}
	secondaryTLS := secondary.Options.(*option.AnyTLSInboundOptions).TLS
	primaryTLS := primary.Options.(*option.AnyTLSInboundOptions).TLS
	if secondaryTLS == nil || !secondaryTLS.Enabled {
		t.Fatal("the IPv6 ingress must serve TLS")
	}
	if secondaryTLS.CertificatePath != primaryTLS.CertificatePath {
		t.Fatalf("both ingresses must serve the same certificate: %q vs %q",
			secondaryTLS.CertificatePath, primaryTLS.CertificatePath)
	}
}

func TestIPv6IngressAcceptsWildcardAndBareAddresses(t *testing.T) {
	info := anytlsNodeInfo("hytron1.wukong.us.kg", "updates.cdn-apple.com")
	for _, listen := range []string{"::", "2401:b60:3d:1b::2"} {
		opts := dualListenOptions("0.0.0.0", listen)
		in, err := getInboundOptionsForListen(secondaryInboundTag("node_37"), info, opts, opts.ListenIP6)
		if err != nil {
			t.Fatalf("listen %q must be accepted: %v", listen, err)
		}
		if got := netip.Addr(*anytlsListenOptions(t, in).Listen); got != netip.MustParseAddr(listen) {
			t.Fatalf("listen %q not applied, got %s", listen, got)
		}
	}
	// Bracketed addresses and "host:port" values are configuration mistakes.
	// Note that an IPv6 address with a port appended (2401:db8::1:443) is a
	// *valid* IPv6 address rather than a parse error, so it is not rejected here;
	// binding it fails on the machine unless that address is really local, which
	// surfaces as a loud AddNode error instead of a silent misconfiguration.
	for _, bad := range []string{"[2401:b60:3d:1b::2]", "45.196.221.58:443"} {
		opts := dualListenOptions("0.0.0.0", bad)
		if _, err := getInboundOptionsForListen(secondaryInboundTag("node_37"), info, opts, opts.ListenIP6); err == nil {
			t.Fatalf("listen value %q must be rejected", bad)
		}
	}
}

func TestSendIPRouteCoversIPv6Ingress(t *testing.T) {
	outbound, rule, err := buildSendIPRoute("node_37", "45.196.221.58", true)
	if err != nil {
		t.Fatalf("build route: %v", err)
	}
	if outbound.Tag != "node_37_out" {
		t.Fatalf("outbound tag mismatch: %q", outbound.Tag)
	}
	bind := outbound.Options.(*option.DirectOutboundOptions).Inet4BindAddress
	if bind == nil || netip.Addr(*bind) != netip.MustParseAddr("45.196.221.58") {
		t.Fatalf("outbound must bind the node SendIP, got %v", bind)
	}
	inbounds := rule.DefaultOptions.Inbound
	if len(inbounds) != 2 || inbounds[0] != "node_37" || inbounds[1] != "node_37_v6" {
		t.Fatalf("the rule must cover both ingresses, got %v", inbounds)
	}

	// Without IPv6 ingress the rule stays exactly as before.
	_, plainRule, err := buildSendIPRoute("node_37", "45.196.221.58", false)
	if err != nil {
		t.Fatalf("build route: %v", err)
	}
	if len(plainRule.DefaultOptions.Inbound) != 1 {
		t.Fatalf("a v4-only node must keep a single-inbound rule, got %v", plainRule.DefaultOptions.Inbound)
	}

	// IPv6 SendIP still binds the v6 side.
	v6Outbound, _, err := buildSendIPRoute("node_38", "2401:b60:3d:bb::2", false)
	if err != nil {
		t.Fatalf("build route: %v", err)
	}
	dialer := v6Outbound.Options.(*option.DirectOutboundOptions)
	if dialer.Inet4BindAddress != nil || dialer.Inet6BindAddress == nil {
		t.Fatal("an IPv6 SendIP must bind the IPv6 source address")
	}

	if _, _, err := buildSendIPRoute("node_39", "not-an-ip", false); err == nil {
		t.Fatal("an invalid SendIP must be reported")
	}
}

func TestHookFoldsIPv6IngressIntoNodeTag(t *testing.T) {
	hook := NewHookServer()
	if got := hook.resolveInboundTag("node_37_v6"); got != "node_37_v6" {
		t.Fatalf("without a link the tag must pass through, got %q", got)
	}
	hook.LinkSecondaryInbound("node_37", secondaryInboundTag("node_37"))
	if got := hook.resolveInboundTag("node_37_v6"); got != "node_37" {
		t.Fatalf("the IPv6 ingress must resolve to the node tag, got %q", got)
	}
	if got := hook.resolveInboundTag("node_37"); got != "node_37" {
		t.Fatalf("the primary tag must stay untouched, got %q", got)
	}
	if got := hook.resolveInboundTag("node_38_v6"); got != "node_38_v6" {
		t.Fatalf("another node must not be affected, got %q", got)
	}
	hook.UnlinkSecondaryInbound(secondaryInboundTag("node_37"))
	if got := hook.resolveInboundTag("node_37_v6"); got != "node_37_v6" {
		t.Fatalf("after unlinking the tag must pass through again, got %q", got)
	}
}
