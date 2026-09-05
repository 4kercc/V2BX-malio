package sing

import (
	"errors"
	"fmt"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/counter"
	"github.com/InazumaV/V2bX/core"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/anytls"
)

// This build is trimmed to AnyTLS only (sing-box core).

func (b *Sing) AddUsers(p *core.AddUsersParams) (added int, err error) {
	in, found := b.box.Inbound().Get(p.Tag)
	if !found {
		return 0, errors.New("the inbound not found")
	}
	switch p.NodeInfo.Type {
	case "anytls":
		us := make([]option.AnyTLSUser, len(p.Users))
		for i := range p.Users {
			us[i] = option.AnyTLSUser{
				Name:     p.Users[i].Uuid,
				Password: p.Users[i].Uuid,
			}
		}
		err = in.(*anytls.Inbound).AddUsers(us)
	default:
		return 0, fmt.Errorf("unsupported node type: %s (this build supports anytls only)", p.NodeInfo.Type)
	}
	if err != nil {
		return 0, err
	}
	return len(p.Users), err
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
	in, found := b.box.Inbound().Get(tag)
	if !found {
		return errors.New("the inbound not found")
	}
	var del UserDeleter
	switch info.Type {
	case "anytls":
		del = in.(*anytls.Inbound)
	default:
		return fmt.Errorf("unsupported node type: %s (this build supports anytls only)", info.Type)
	}
	uuids := make([]string, len(users))
	for i := range users {
		uuids[i] = users[i].Uuid
	}
	err := del.DelUsers(uuids)
	if err != nil {
		return err
	}
	// Drop the removed users' traffic counters, otherwise stale entries
	// accumulate in the hook for every expired/deleted user over time.
	if v, ok := b.hookServer.counter.Load(tag); ok {
		c := v.(*counter.TrafficCounter)
		for i := range uuids {
			c.Delete(uuids[i])
		}
	}
	return nil
}
