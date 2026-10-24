package sing

import (
	"encoding/base64"
	"fmt"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/counter"
	"github.com/InazumaV/V2bX/core"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/anytls"
	"github.com/sagernet/sing-box/protocol/hysteria"
	"github.com/sagernet/sing-box/protocol/hysteria2"
	"github.com/sagernet/sing-box/protocol/shadowsocks"
	"github.com/sagernet/sing-box/protocol/trojan"
	"github.com/sagernet/sing-box/protocol/tuic"
	"github.com/sagernet/sing-box/protocol/vless"
	"github.com/sagernet/sing-box/protocol/vmess"
)

// nodeInboundTags lists the tags a node's user list has to be applied to: the
// node's own inbound plus, when the node accepts IPv6 clients, its extra
// ingress. Both serve the same users, so user sync must reach both.
func (b *Sing) nodeInboundTags(tag string) []string {
	tags := []string{tag}
	secondary := secondaryInboundTag(tag)
	if _, found := b.box.Inbound().Get(secondary); found {
		tags = append(tags, secondary)
	}
	return tags
}

func (b *Sing) AddUsers(p *core.AddUsersParams) (added int, err error) {
	for _, tag := range b.nodeInboundTags(p.Tag) {
		in, found := b.box.Inbound().Get(tag)
		if !found {
			return 0, fmt.Errorf("the inbound %s not found", tag)
		}
		switch p.NodeInfo.Type {
		case "vless":
			us := make([]option.VLESSUser, len(p.Users))
			for i := range p.Users {
				us[i] = option.VLESSUser{
					Name: p.Users[i].Uuid,
					Flow: p.VAllss.Flow,
					UUID: p.Users[i].Uuid,
				}
			}
			err = in.(*vless.Inbound).AddUsers(us)
		case "vmess":
			us := make([]option.VMessUser, len(p.Users))
			for i := range p.Users {
				us[i] = option.VMessUser{
					Name: p.Users[i].Uuid,
					UUID: p.Users[i].Uuid,
				}
			}
			err = in.(*vmess.Inbound).AddUsers(us)
		case "shadowsocks":
			us := make([]option.ShadowsocksUser, len(p.Users))
			for i := range p.Users {
				var password = p.Users[i].Uuid
				switch p.Shadowsocks.Cipher {
				case "2022-blake3-aes-128-gcm":
					password = base64.StdEncoding.EncodeToString([]byte(password[:16]))
				case "2022-blake3-aes-256-gcm":
					password = base64.StdEncoding.EncodeToString([]byte(password[:32]))
				}
				us[i] = option.ShadowsocksUser{
					Name:     p.Users[i].Uuid,
					Password: password,
				}
			}
			err = in.(*shadowsocks.MultiInbound).AddUsers(us)
		case "trojan":
			us := make([]option.TrojanUser, len(p.Users))
			for i := range p.Users {
				us[i] = option.TrojanUser{
					Name:     p.Users[i].Uuid,
					Password: p.Users[i].Uuid,
				}
			}
			err = in.(*trojan.Inbound).AddUsers(us)
		case "tuic":
			us := make([]option.TUICUser, len(p.Users))
			id := make([]int, len(p.Users))
			for i := range p.Users {
				us[i] = option.TUICUser{
					Name:     p.Users[i].Uuid,
					UUID:     p.Users[i].Uuid,
					Password: p.Users[i].Uuid,
				}
				id[i] = p.Users[i].Id
			}
			err = in.(*tuic.Inbound).AddUsers(us, id)
		case "hysteria":
			us := make([]option.HysteriaUser, len(p.Users))
			for i := range p.Users {
				us[i] = option.HysteriaUser{
					Name:       p.Users[i].Uuid,
					AuthString: p.Users[i].Uuid,
				}
			}
			err = in.(*hysteria.Inbound).AddUsers(us)
		case "hysteria2":
			us := make([]option.Hysteria2User, len(p.Users))
			id := make([]int, len(p.Users))
			for i := range p.Users {
				us[i] = option.Hysteria2User{
					Name:     p.Users[i].Uuid,
					Password: p.Users[i].Uuid,
				}
				id[i] = p.Users[i].Id
			}
			err = in.(*hysteria2.Inbound).AddUsers(us, id)
		case "anytls":
			us := make([]option.AnyTLSUser, len(p.Users))
			for i := range p.Users {
				us[i] = option.AnyTLSUser{
					Name:     p.Users[i].Uuid,
					Password: p.Users[i].Uuid,
				}
			}
			err = in.(*anytls.Inbound).AddUsers(us)
		}
		if err != nil {
			return 0, err
		}
	}
	return len(p.Users), nil
}

func (b *Sing) GetUserTraffic(tag, uuid string, reset bool) (up int64, down int64) {
	if v, ok := b.hookServer.counter.Load(tag); ok {
		c := v.(*counter.TrafficCounter)
		up = c.GetUpCount(uuid)
		down = c.GetDownCount(uuid)
		if reset {
			c.Reset(uuid)
		}
		return
	}
	return 0, 0
}

type UserDeleter interface {
	DelUsers(uuid []string) error
}

func (b *Sing) DelUsers(users []panel.UserInfo, tag string, info *panel.NodeInfo) error {
	uuids := make([]string, len(users))
	for i := range users {
		uuids[i] = users[i].Uuid
	}
	for _, t := range b.nodeInboundTags(tag) {
		in, found := b.box.Inbound().Get(t)
		if !found {
			return fmt.Errorf("the inbound %s not found", t)
		}
		var del UserDeleter
		switch info.Type {
		case "vmess":
			del = in.(*vmess.Inbound)
		case "vless":
			del = in.(*vless.Inbound)
		case "shadowsocks":
			del = in.(*shadowsocks.MultiInbound)
		case "trojan":
			del = in.(*trojan.Inbound)
		case "tuic":
			del = in.(*tuic.Inbound)
		case "hysteria":
			del = in.(*hysteria.Inbound)
		case "hysteria2":
			del = in.(*hysteria2.Inbound)
		case "anytls":
			del = in.(*anytls.Inbound)
		default:
			return fmt.Errorf("unsupported node type: %s", info.Type)
		}
		err := del.DelUsers(uuids)
		if err != nil {
			return err
		}
	}
	// Drop the removed users' traffic counters, otherwise stale entries
	// accumulate in the hook for every expired/deleted user over time. The
	// counters live under the node tag, IPv6 traffic included.
	if v, ok := b.hookServer.counter.Load(tag); ok {
		c := v.(*counter.TrafficCounter)
		for i := range uuids {
			c.Delete(uuids[i])
		}
	}
	return nil
}
