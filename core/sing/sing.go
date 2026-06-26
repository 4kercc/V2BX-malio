package sing

import (
	"context"
	"fmt"
	"net/netip"
	"os"
	"strconv"

	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"

	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	box "github.com/sagernet/sing-box"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/common/json/badoption"
)

var _ vCore.Core = (*Sing)(nil)

type DNSConfig struct {
	Servers []map[string]interface{} `json:"servers"`
	Rules   []map[string]interface{} `json:"rules"`
}

type Sing struct {
	box        *box.Box
	ctx        context.Context
	hookServer *HookServer
	router     adapter.Router
	logFactory log.Factory
}

func init() {
	vCore.RegisterCore("sing", New)
}

func New(c *conf.CoreConfig) (vCore.Core, error) {
	ctx := context.Background()
	ctx = box.Context(ctx, include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry())
	options := option.Options{}
	if len(c.SingConfig.OriginalPath) != 0 {
		data, err := os.ReadFile(c.SingConfig.OriginalPath)
		if err != nil {
			return nil, fmt.Errorf("read original config error: %s", err)
		}
		options, err = json.UnmarshalExtendedContext[option.Options](ctx, data)
		if err != nil {
			return nil, fmt.Errorf("unmarshal original config error: %s", err)
		}
	}
	options.Log = &option.LogOptions{
		Disabled:  c.SingConfig.LogConfig.Disabled,
		Level:     c.SingConfig.LogConfig.Level,
		Timestamp: c.SingConfig.LogConfig.Timestamp,
		Output:    c.SingConfig.LogConfig.Output,
	}
	options.NTP = &option.NTPOptions{
		Enabled:       c.SingConfig.NtpConfig.Enable,
		WriteToSystem: true,
		ServerOptions: option.ServerOptions{
			Server:     c.SingConfig.NtpConfig.Server,
			ServerPort: c.SingConfig.NtpConfig.ServerPort,
		},
	}
	
	// Enable auto_detect_interface to automatically select the correct source IP
	// This helps achieve "same in, same out" behavior at the system level
	if options.Route == nil {
		options.Route = &option.RouteOptions{}
	}
	options.Route.AutoDetectInterface = true

	// Auto-generate outbounds and routing rules for same-IP-in-out
	// Uses SendIP from node config to bind outbound source address
	// Rules are PREPENDED to take priority over any catch-all rules in sing_origin.json
	if len(c.SingConfig.NodesConfig) > 0 {
		// Collect auto-generated rules to prepend
		var autoRules []option.Rule

		for _, nodeConf := range c.SingConfig.NodesConfig {
			sendIP := nodeConf.Options.SendIP
			if sendIP == "" || sendIP == "0.0.0.0" {
				continue
			}
			addr, parseErr := netip.ParseAddr(sendIP)
			if parseErr != nil {
				log.Warn(fmt.Sprintf("Invalid SendIP %s for NodeID %d: %s", sendIP, nodeConf.ApiConfig.NodeID, parseErr))
				continue
			}

			// Generate tag using same logic as node/controller.buildNodeTag
			tag := nodeConf.Options.Name
			if tag == "" {
				tag = "node_" + strconv.Itoa(nodeConf.ApiConfig.NodeID)
			}
			outboundTag := tag + "_out"

			// Build dialer options for binding source IP
			bindAddr := badoption.Addr(addr)
			dialerOpts := option.DialerOptions{}
			if addr.Is4() {
				dialerOpts.Inet4BindAddress = &bindAddr
			} else {
				dialerOpts.Inet6BindAddress = &bindAddr
			}

			// Create direct outbound with bind address
			directOpts := option.DirectOutboundOptions{
				DialerOptions: dialerOpts,
			}

			outbound := option.Outbound{
				Tag:     outboundTag,
				Type:    C.TypeDirect,
				Options: &directOpts,
			}

			// Append outbound
			if options.Outbounds == nil {
				options.Outbounds = []option.Outbound{}
			}
			options.Outbounds = append(options.Outbounds, outbound)

			// Build routing rule: inbound tag -> specific outbound
			rule := option.Rule{
				Type: C.RuleTypeDefault,
				DefaultOptions: option.DefaultRule{
					RawDefaultRule: option.RawDefaultRule{
						Inbound: badoption.Listable[string]{tag},
					},
					RuleAction: option.RuleAction{
						Action: C.RuleActionTypeRoute,
						RouteOptions: option.RouteActionOptions{
							Outbound: outboundTag,
						},
					},
				},
			}
			autoRules = append(autoRules, rule)

			log.Info(fmt.Sprintf("Auto-configured outbound %s with bind_address %s for node %s (NodeID=%d)",
				outboundTag, sendIP, tag, nodeConf.ApiConfig.NodeID))
		}

		// Prepend auto-generated rules before existing rules
		// so they take priority over catch-all rules in sing_origin.json
		if len(autoRules) > 0 {
			if options.Route == nil {
				options.Route = &option.RouteOptions{}
			}
			if options.Route.Rules == nil {
				options.Route.Rules = []option.Rule{}
			}
			options.Route.Rules = append(autoRules, options.Route.Rules...)
		}
	}

	os.Setenv("SING_DNS_PATH", "")
	b, err := box.New(box.Options{
		Context: ctx,
		Options: options,
	})
	if err != nil {
		return nil, err
	}
	hs := NewHookServer()
	b.Router().AppendTracker(hs)
	return &Sing{
		ctx:        b.Router().GetCtx(),
		box:        b,
		hookServer: hs,
		router:     b.Router(),
		logFactory: b.LogFactory(),
	}, nil
}

func (b *Sing) Start() error {
	return b.box.Start()
}

func (b *Sing) Close() error {
	return b.box.Close()
}

func (b *Sing) Protocols() []string {
	return []string{
		"vmess",
		"vless",
		"shadowsocks",
		"trojan",
		"tuic",
		"anytls",
		"hysteria",
		"hysteria2",
	}
}

func (b *Sing) Type() string {
	return "sing"
}
