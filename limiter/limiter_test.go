package limiter

import (
	"sync"
	"testing"
)

func TestCheckLimitUsesTrackedIPsWhenPanelAliveListIsEmpty(t *testing.T) {
	limiter := &Limiter{
		UserOnlineIP:  new(sync.Map),
		OldUserOnline: new(sync.Map),
		UserLimitInfo: new(sync.Map),
		SpeedLimiter:  new(sync.Map),
		AliveList:     map[int]int{},
	}
	limiter.UserLimitInfo.Store("node-user", &UserLimitInfo{
		UID:         7,
		DeviceLimit: 1,
	})

	if _, reject := limiter.CheckLimit("node-user", "198.51.100.10", true, true); reject {
		t.Fatal("first IP should be accepted")
	}
	if _, reject := limiter.CheckLimit("node-user", "198.51.100.11", true, true); !reject {
		t.Fatal("second IP should be rejected when the panel alive list is empty")
	}
}

func TestCheckLimitKeepsDeviceLimitAcrossOnlineReportReset(t *testing.T) {
	limiter := &Limiter{
		UserOnlineIP:  new(sync.Map),
		OldUserOnline: new(sync.Map),
		UserLimitInfo: new(sync.Map),
		SpeedLimiter:  new(sync.Map),
		AliveList:     map[int]int{},
	}
	limiter.UserLimitInfo.Store("node-user", &UserLimitInfo{
		UID:         7,
		DeviceLimit: 1,
	})

	limiter.CheckLimit("node-user", "198.51.100.10", true, true)
	if _, err := limiter.GetOnlineDevice(); err != nil {
		t.Fatal(err)
	}
	if _, reject := limiter.CheckLimit("node-user", "198.51.100.11", true, true); !reject {
		t.Fatal("a new IP should remain rejected after the online report resets the current map")
	}
}
