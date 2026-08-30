package limiter

import (
	"errors"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/format"
	"github.com/InazumaV/V2bX/conf"
	"github.com/juju/ratelimit"
)

var limitLock sync.RWMutex
var limiter map[string]*Limiter

func Init() {
	limiter = map[string]*Limiter{}
}

type Limiter struct {
	DomainRules   []*regexp.Regexp
	ProtocolRules []string
	SpeedLimit    int
	UserOnlineIP  *sync.Map      // Key: TagUUID, value: {Key: Ip, value: Uid}
	OldUserOnline *sync.Map      // Key: Ip, value: Uid
	OldIPCount    map[int]int    // Key: Uid, value: number of IPs tracked in OldUserOnline (guarded by countMu)
	countMu       sync.Mutex     // guards OldIPCount and the OldUserOnline swap in GetOnlineDevice
	UUIDtoUID     map[string]int // Key: UUID, value: Uid
	UserLimitInfo *sync.Map      // Key: TagUUID value: UserLimitInfo
	SpeedLimiter  *sync.Map      // key: TagUUID, value: *ratelimit.Bucket
	AliveList     map[int]int    // Key: Uid, value: alive_ip
}

type UserLimitInfo struct {
	UID               int
	SpeedLimit        int
	DeviceLimit       int
	DynamicSpeedLimit int
	ExpireTime        int64
	OverLimit         bool
}

func AddLimiter(tag string, l *conf.LimitConfig, users []panel.UserInfo, aliveList map[int]int) *Limiter {
	info := &Limiter{
		SpeedLimit:    l.SpeedLimit,
		UserOnlineIP:  new(sync.Map),
		UserLimitInfo: new(sync.Map),
		SpeedLimiter:  new(sync.Map),
		AliveList:     aliveList,
		OldUserOnline: new(sync.Map),
		OldIPCount:    make(map[int]int),
	}
	uuidmap := make(map[string]int)
	for i := range users {
		uuidmap[users[i].Uuid] = users[i].Id
		userLimit := &UserLimitInfo{}
		userLimit.UID = users[i].Id
		if users[i].SpeedLimit != 0 {
			userLimit.SpeedLimit = users[i].SpeedLimit
		}
		if users[i].DeviceLimit != 0 {
			userLimit.DeviceLimit = users[i].DeviceLimit
		}
		userLimit.OverLimit = false
		info.UserLimitInfo.Store(format.UserTag(tag, users[i].Uuid), userLimit)
	}
	info.UUIDtoUID = uuidmap
	limitLock.Lock()
	limiter[tag] = info
	limitLock.Unlock()
	return info
}

func GetLimiter(tag string) (info *Limiter, err error) {
	limitLock.RLock()
	info, ok := limiter[tag]
	limitLock.RUnlock()
	if !ok {
		return nil, errors.New("not found")
	}
	return info, nil
}

func DeleteLimiter(tag string) {
	limitLock.Lock()
	delete(limiter, tag)
	limitLock.Unlock()
}

func (l *Limiter) UpdateUser(tag string, added []panel.UserInfo, deleted []panel.UserInfo) {
	for i := range deleted {
		l.UserLimitInfo.Delete(format.UserTag(tag, deleted[i].Uuid))
		l.UserOnlineIP.Delete(format.UserTag(tag, deleted[i].Uuid))
		l.SpeedLimiter.Delete(format.UserTag(tag, deleted[i].Uuid))
		delete(l.UUIDtoUID, deleted[i].Uuid)
		delete(l.AliveList, deleted[i].Id)
	}
	for i := range added {
		userLimit := &UserLimitInfo{
			UID: added[i].Id,
		}
		if added[i].SpeedLimit != 0 {
			userLimit.SpeedLimit = added[i].SpeedLimit
			userLimit.ExpireTime = 0
		}
		if added[i].DeviceLimit != 0 {
			userLimit.DeviceLimit = added[i].DeviceLimit
		}
		userLimit.OverLimit = false
		l.UserLimitInfo.Store(format.UserTag(tag, added[i].Uuid), userLimit)
		l.UUIDtoUID[added[i].Uuid] = added[i].Id
	}
}

func (l *Limiter) UpdateDynamicSpeedLimit(tag, uuid string, limit int, expire time.Time) error {
	if v, ok := l.UserLimitInfo.Load(format.UserTag(tag, uuid)); ok {
		info := v.(*UserLimitInfo)
		info.DynamicSpeedLimit = limit
		info.ExpireTime = expire.Unix()
	} else {
		return errors.New("not found")
	}
	return nil
}

func (l *Limiter) CheckLimit(taguuid string, ip string, isTcp bool, noSSUDP bool) (Bucket *ratelimit.Bucket, Reject bool) {
	// check if ipv4 mapped ipv6
	ip = strings.TrimPrefix(ip, "::ffff:")

	// check and gen speed limit Bucket
	nodeLimit := l.SpeedLimit
	userLimit := 0
	deviceLimit := 0
	var uid int
	if v, ok := l.UserLimitInfo.Load(taguuid); ok {
		u := v.(*UserLimitInfo)
		deviceLimit = u.DeviceLimit
		uid = u.UID
		if u.ExpireTime < time.Now().Unix() && u.ExpireTime != 0 {
			if u.SpeedLimit != 0 {
				userLimit = u.SpeedLimit
				u.DynamicSpeedLimit = 0
				u.ExpireTime = 0
			} else {
				l.UserLimitInfo.Delete(taguuid)
			}
		} else {
			userLimit = determineSpeedLimit(u.SpeedLimit, u.DynamicSpeedLimit)
		}
	} else {
		return nil, true
	}
	if noSSUDP {
		// Store online user for device limit
		newipMap := new(sync.Map)
		newipMap.Store(ip, uid)
		aliveIp := l.AliveList[uid]
		// If any device is online
		if v, loaded := l.UserOnlineIP.LoadOrStore(taguuid, newipMap); loaded {
			oldipMap := v.(*sync.Map)
			currentIPCount := l.countUserIPs(oldipMap)
			// If this is a new ip
			if _, loaded := oldipMap.LoadOrStore(ip, uid); !loaded {
				// O(1): take the tracked count and drop ip from the previous report if it belongs to this user
				oldIPCount := l.consumeOldIP(uid, ip)
				knownIPCount := currentIPCount
				if aliveIp > knownIPCount {
					knownIPCount = aliveIp
				}
				if oldIPCount > knownIPCount {
					knownIPCount = oldIPCount
				}
				if deviceLimit > 0 && deviceLimit <= knownIPCount {
					oldipMap.Delete(ip)
					return nil, true
				}
			}
		} else if l.dropOldIP(uid, ip) {
			// ip was reported in the previous cycle: first ip of this user this cycle is always accepted
		} else {
			knownIPCount := l.getOldIPCount(uid)
			if aliveIp > knownIPCount {
				knownIPCount = aliveIp
			}
			if deviceLimit > 0 && deviceLimit <= knownIPCount {
				l.UserOnlineIP.Delete(taguuid)
				return nil, true
			}
		}
	}

	limit := int64(determineSpeedLimit(nodeLimit, userLimit)) * 1000000 / 8 // If you need the Speed limit
	if limit > 0 {
		Bucket = ratelimit.NewBucketWithQuantum(time.Second, limit, limit) // Byte/s
		if v, ok := l.SpeedLimiter.LoadOrStore(taguuid, Bucket); ok {
			return v.(*ratelimit.Bucket), false
		} else {
			l.SpeedLimiter.Store(taguuid, Bucket)
			return Bucket, false
		}
	} else {
		return nil, false
	}
}

func (l *Limiter) GetOnlineDevice() (*[]panel.OnlineUser, error) {
	var onlineUser []panel.OnlineUser
	// Build the next snapshot first and swap atomically, so CheckLimit never
	// observes a half-rebuilt OldUserOnline and device limits hold across reports.
	newOld := new(sync.Map)
	newCount := make(map[int]int)
	l.UserOnlineIP.Range(func(key, value interface{}) bool {
		taguuid := key.(string)
		ipMap := value.(*sync.Map)
		ipMap.Range(func(key, value interface{}) bool {
			uid := value.(int)
			ip := key.(string)
			newOld.Store(ip, uid)
			newCount[uid]++
			onlineUser = append(onlineUser, panel.OnlineUser{UID: uid, IP: ip})
			return true
		})
		l.UserOnlineIP.Delete(taguuid) // Reset online device
		return true
	})
	l.countMu.Lock()
	l.OldUserOnline = newOld
	l.OldIPCount = newCount
	l.countMu.Unlock()

	return &onlineUser, nil
}

func (l *Limiter) countUserIPs(ipMap *sync.Map) int {
	if ipMap == nil {
		return 0
	}

	count := 0
	ipMap.Range(func(_, _ interface{}) bool {
		count++
		return true
	})
	return count
}

// getOldIPCount returns the tracked number of IPs uid has in OldUserOnline in O(1).
func (l *Limiter) getOldIPCount(uid int) int {
	l.countMu.Lock()
	defer l.countMu.Unlock()
	return l.OldIPCount[uid]
}

// dropOldIP removes ip from OldUserOnline when it belongs to uid and keeps the
// per-uid counter in sync. Reports whether the ip was previously tracked.
func (l *Limiter) dropOldIP(uid int, ip string) bool {
	l.countMu.Lock()
	defer l.countMu.Unlock()
	if v, loaded := l.OldUserOnline.Load(ip); loaded && v.(int) == uid {
		l.OldUserOnline.Delete(ip)
		if l.OldIPCount[uid] > 0 {
			l.OldIPCount[uid]--
		}
		return true
	}
	return false
}

// consumeOldIP drops ip from the previous report when owned by uid and returns
// the user's remaining tracked IP count, atomically.
func (l *Limiter) consumeOldIP(uid int, ip string) int {
	l.countMu.Lock()
	defer l.countMu.Unlock()
	if v, loaded := l.OldUserOnline.Load(ip); loaded && v.(int) == uid {
		l.OldUserOnline.Delete(ip)
		if l.OldIPCount[uid] > 0 {
			l.OldIPCount[uid]--
		}
	}
	return l.OldIPCount[uid]
}

type UserIpList struct {
	Uid    int      `json:"Uid"`
	IpList []string `json:"Ips"`
}
