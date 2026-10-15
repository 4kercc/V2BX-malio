package sing

import (
	"context"
	"fmt"
	"net"
	"sync"

	"github.com/InazumaV/V2bX/common/format"
	"github.com/InazumaV/V2bX/common/rate"

	"github.com/InazumaV/V2bX/limiter"

	"github.com/InazumaV/V2bX/common/counter"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/log"
	N "github.com/sagernet/sing/common/network"
)

var _ adapter.ConnectionTracker = (*HookServer)(nil)

type HookServer struct {
	counter sync.Map //map[string]*counter.TrafficCounter
	// secondaryTags maps the tag of an extra IPv6 ingress to the node's primary
	// tag, so its connections use that node's limiter and traffic counter.
	secondaryTags sync.Map //map[string]string
}

func (h *HookServer) ModeList() []string {
	return nil
}

func NewHookServer() *HookServer {
	server := &HookServer{
		counter: sync.Map{},
	}
	return server
}

// LinkSecondaryInbound records that connections arriving on secondary belong to
// the node registered under primary.
func (h *HookServer) LinkSecondaryInbound(primary, secondary string) {
	h.secondaryTags.Store(secondary, primary)
}

func (h *HookServer) UnlinkSecondaryInbound(secondary string) {
	h.secondaryTags.Delete(secondary)
}

// resolveInboundTag folds an extra ingress tag back into its node tag. Everything
// downstream (limiter registry, user tag formatting, traffic counters) is keyed
// by the node tag, so an IPv6 client is limited and accounted exactly like an
// IPv4 one.
func (h *HookServer) resolveInboundTag(tag string) string {
	if primary, ok := h.secondaryTags.Load(tag); ok {
		return primary.(string)
	}
	return tag
}

func (h *HookServer) RoutedConnection(_ context.Context, conn net.Conn, m adapter.InboundContext, _ adapter.Rule, _ adapter.Outbound) net.Conn {
	inbound := h.resolveInboundTag(m.Inbound)
	l, err := limiter.GetLimiter(inbound)
	if err != nil {
		log.Warn("get limiter for ", inbound, " error: ", err)
		return conn
	}
	taguuid := format.UserTag(inbound, m.User)
	ip := m.Source.Addr.String()
	if b, r := l.CheckLimit(taguuid, ip, true, true); r {
		conn.Close()
		log.Error("[", inbound, "] ", "Limited ", m.User, " by ip or conn")
		return conn
	} else if b != nil {
		conn = rate.NewConnRateLimiter(conn, b)
	}
	if l != nil {
		destStr := m.Destination.AddrString()
		protocol := m.Protocol
		if l.CheckDomainRule(destStr) {
			log.Error(fmt.Sprintf(
				"User %s access domain %s reject by rule",
				m.User,
				destStr))
			conn.Close()
			return conn
		}
		if len(protocol) != 0 {
			if l.CheckProtocolRule(protocol) {
				log.Error(fmt.Sprintf(
					"User %s access protocol %s reject by rule",
					m.User,
					protocol))
				conn.Close()
				return conn
			}
		}
	}
	var t *counter.TrafficCounter
	if c, ok := h.counter.Load(inbound); !ok {
		t = counter.NewTrafficCounter()
		h.counter.Store(inbound, t)
	} else {
		t = c.(*counter.TrafficCounter)
	}
	conn = counter.NewConnCounter(conn, t.GetCounter(m.User))
	return conn
}

func (h *HookServer) RoutedPacketConnection(_ context.Context, conn N.PacketConn, m adapter.InboundContext, _ adapter.Rule, _ adapter.Outbound) N.PacketConn {
	inbound := h.resolveInboundTag(m.Inbound)
	l, err := limiter.GetLimiter(inbound)
	if err != nil {
		log.Warn("get limiter for ", inbound, " error: ", err)
		return conn
	}
	ip := m.Source.Addr.String()
	taguuid := format.UserTag(inbound, m.User)
	if b, r := l.CheckLimit(taguuid, ip, false, false); r {
		conn.Close()
		log.Error("[", inbound, "] ", "Limited ", m.User, " by ip or conn")
		return conn
	} else if b != nil {
		//conn = rate.NewPacketConnCounter(conn, b)
	}
	if l != nil {
		destStr := m.Destination.AddrString()
		protocol := m.Destination.Network()
		if l.CheckDomainRule(destStr) {
			log.Error(fmt.Sprintf(
				"User %s access domain %s reject by rule",
				m.User,
				destStr))
			conn.Close()
			return conn
		}
		if len(protocol) != 0 {
			if l.CheckProtocolRule(protocol) {
				log.Error(fmt.Sprintf(
					"User %s access protocol %s reject by rule",
					m.User,
					protocol))
				conn.Close()
				return conn
			}
		}
	}
	var t *counter.TrafficCounter
	if c, ok := h.counter.Load(inbound); !ok {
		t = counter.NewTrafficCounter()
		h.counter.Store(inbound, t)
	} else {
		t = c.(*counter.TrafficCounter)
	}
	conn = counter.NewPacketConnCounter(conn, t.GetCounter(m.User))
	return conn
}
