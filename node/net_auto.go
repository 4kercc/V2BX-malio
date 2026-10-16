package node

import (
	"context"
	"fmt"
	"net"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/InazumaV/V2bX/conf"
	log "github.com/sirupsen/logrus"
)

// PrepareOptions resolves everything that has to be known before the cores are
// built and the nodes start:
//
//   - the machine-level "Cert" block: its domain list ("auto" takes the names
//     the machine's nodes declare) and its file paths, then each node inherits
//     it field by field (an explicit per-node value always wins);
//   - "ListenIP"/"SendIP": "auto" derives the node's address from its landing
//     domain (the A record) and keeps the exit on that same address, which is
//     the same-in/same-out pairing that used to be written out by hand.
//
// It is idempotent: the resolved values are stored back into the node options
// while the auto flags remember that they were derived, so a config reload
// re-derives them instead of freezing the first result.
func PrepareOptions(machineCert *conf.CertConfig, nodes []conf.NodeConfig) error {
	mc := resolveMachineCert(machineCert, nodes)

	ownerSet := false
	for i := range nodes {
		opt := &nodes[i].Options
		label := nodeLabel(&nodes[i])
		// Resolve "auto" addresses *before* the machine certificate is merged:
		// the node's own landing domain is what describes its address, while the
		// machine block carries every node's domain and would resolve to another
		// node's IP.
		if err := resolveAutoAddress(opt, label); err != nil {
			// Only this node can fix it (DNS not set up yet, typo, or a landing
			// domain that is not this machine's). Skip the node instead of
			// failing the whole process: the machine's other nodes keep serving.
			nodes[i].Disabled = true
			nodes[i].DisabledReason = err.Error()
			log.WithFields(log.Fields{"node": label, "err": err}).Error(
				"节点已跳过：ListenIP=auto 依赖该节点域名解析到本机，请先配好 A 记录，或把该节点的 ListenIP 改成 0.0.0.0 / 具体 IP 后重启")
			continue
		}
		if mc != nil {
			opt.CertConfig = conf.MergeCertConfig(mc, opt.CertConfig)
			// Exactly one node issues and renews the shared certificate.
			if !ownerSet {
				opt.CertConfig.CertOwner = true
				ownerSet = true
			}
		}
	}
	if mc != nil {
		log.WithFields(log.Fields{
			"domains": strings.Join(effectiveCertDomains(mc), ","),
			"cert":    mc.CertFile,
		}).Info("Machine certificate is shared by all nodes on this host")
	}
	return nil
}

func nodeLabel(n *conf.NodeConfig) string {
	if n.Options.Name != "" {
		return n.Options.Name
	}
	return fmt.Sprintf("node_%d", n.ApiConfig.NodeID)
}

// resolveMachineCert fills in the machine certificate's derived defaults and
// resolves the "auto" domain placeholder. It returns nil when the machine block
// cannot be used, so the nodes simply keep their own certificate settings
// instead of silently sharing a half-configured certificate.
func resolveMachineCert(machineCert *conf.CertConfig, nodes []conf.NodeConfig) *conf.CertConfig {
	if machineCert == nil {
		return nil
	}
	mc := *machineCert
	if mc.CertMode == "" {
		mc.CertMode = "http"
	}
	if mc.HasAutoDomain() {
		domains := collectNodeCertDomains(nodes)
		if len(domains) == 0 {
			log.Error("Cert.Domains=auto 但没有任何节点配置了 CertDomain，机器级证书已停用（请在 Cert.Domains 里直接写明域名）")
			return nil
		}
		mc.CertDomains = domains
	}
	domains := mc.DomainsOf()
	if len(domains) == 0 {
		log.Error("Cert 块没有可用的域名（Domains / CertDomain 均为空），机器级证书已停用")
		return nil
	}
	if mc.CertFile == "" {
		mc.CertFile = path.Join("/etc/V2bX/cert/machine", "fullchain.pem")
	}
	if mc.KeyFile == "" {
		mc.KeyFile = path.Join("/etc/V2bX/cert/machine", "privkey.pem")
	}
	if mc.Email == "" && mc.CertMode != "file" && mc.CertMode != "self" {
		mc.Email = "acme@" + domains[0]
	}
	return &mc
}

func effectiveCertDomains(cert *conf.CertConfig) []string {
	return cert.DomainsOf()
}

// collectNodeCertDomains gathers the landing domains declared by this machine's
// nodes, which is what "Domains": ["auto"] resolves to. The panel's server host
// cannot be used here: it is only known after a node connects to the panel,
// while the machine certificate is fixed before the nodes start.
func collectNodeCertDomains(nodes []conf.NodeConfig) []string {
	seen := map[string]bool{}
	var out []string
	for i := range nodes {
		if nodes[i].Options.CertConfig == nil {
			continue
		}
		for _, d := range nodes[i].Options.CertConfig.DomainsOf() {
			if strings.EqualFold(d, "auto") {
				continue
			}
			if normalizeCertDomain(d) == "" || seen[d] {
				continue
			}
			seen[d] = true
			out = append(out, d)
		}
	}
	return out
}

// resolveAutoAddress turns "auto" into concrete addresses. ListenIP comes from
// the node's landing domain (its A record), SendIP from the resolved listen
// address: the pairing that has to be written by hand today.
func resolveAutoAddress(opt *conf.Options, label string) error {
	if opt.ListenIP == "auto" {
		opt.ListenIPAuto = true
	}
	if opt.SendIP == "auto" {
		opt.SendIPAuto = true
	}
	if !opt.ListenIPAuto && !opt.SendIPAuto {
		return nil
	}

	listen := opt.ListenIP
	if opt.ListenIPAuto {
		domain := autoListenDomain(opt)
		if domain == "" {
			return fmt.Errorf("%s: ListenIP=auto 需要一个域名来解析本机地址（请在节点的 CertDomain 里写该节点的落地域名，或直接填 ListenIP）", label)
		}
		ip, err := resolveIPv4(domain, label)
		if err != nil {
			return err
		}
		listen = ip
		opt.ListenIP = ip
		log.WithFields(log.Fields{"node": label, "domain": domain, "listen": ip}).Info("ListenIP=auto resolved from the landing domain")
	}

	if !opt.SendIPAuto {
		return nil
	}
	switch {
	case listen == "" || listen == "0.0.0.0" || listen == "::":
		// A wildcard cannot be used as a source address: keep the kernel's
		// default exit and say so instead of binding something meaningless.
		opt.SendIP = "0.0.0.0"
		log.WithFields(log.Fields{"node": label, "listen": listen}).
			Warn("SendIP=auto 但监听地址是通配地址，出口保持内核默认（如需同进同出请给节点绑具体 IP）")
	default:
		opt.SendIP = listen
		log.WithFields(log.Fields{"node": label, "send": listen}).Info("SendIP=auto follows the listen address (same in, same out)")
	}
	return nil
}

// autoListenDomain picks the domain whose A record describes this node: its own
// landing name (CertDomain) comes first, then its own domain list. The machine
// certificate's list is deliberately not consulted — it belongs to the whole
// host and would point the node at another node's address.
func autoListenDomain(opt *conf.Options) string {
	if opt.CertConfig == nil {
		return ""
	}
	if d := strings.TrimSpace(opt.CertConfig.CertDomain); d != "" && !strings.EqualFold(d, "auto") {
		return d
	}
	for _, d := range opt.CertConfig.CertDomains {
		if d = strings.TrimSpace(d); d != "" && !strings.EqualFold(d, "auto") {
			return d
		}
	}
	return ""
}

// resolveIPv4 looks up the A record of a domain, retrying briefly so a DNS
// hiccup during boot does not take the machine's nodes down. Several addresses
// resolve to the smallest one, deterministically, with a warning: an ambiguous
// record usually means the node should name its own address explicitly.
func resolveIPv4(domain, label string) (string, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		addrs, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", domain)
		cancel()
		if err == nil && len(addrs) > 0 {
			values := make([]string, 0, len(addrs))
			for _, a := range addrs {
				values = append(values, a.Unmap().String())
			}
			sort.Strings(values)
			if len(values) > 1 {
				log.WithFields(log.Fields{
					"node":    label,
					"domain":  domain,
					"chosen":  values[0],
					"records": strings.Join(values, ","),
				}).Warn("ListenIP=auto 的域名解析出多个 A 记录，取最小的一个（多 IP 机器建议每个节点写自己的域名或直接写 ListenIP）")
			}
			return values[0], nil
		}
		if err != nil {
			lastErr = err
		} else {
			lastErr = fmt.Errorf("域名 %s 没有 A 记录", domain)
		}
		time.Sleep(2 * time.Second)
	}
	return "", fmt.Errorf("%s: 解析 %s 失败（ListenIP=auto）: %s", label, domain, lastErr)
}
