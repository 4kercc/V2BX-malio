package node

import (
	"testing"

	"github.com/InazumaV/V2bX/api/panel"
)

func TestCompareUserListDetectsDeviceLimitChanges(t *testing.T) {
	oldUsers := []panel.UserInfo{{Uuid: "user-1", SpeedLimit: 0, DeviceLimit: 1}}
	newUsers := []panel.UserInfo{{Uuid: "user-1", SpeedLimit: 0, DeviceLimit: 2}}

	deleted, added := compareUserList(oldUsers, newUsers)
	if len(deleted) != 1 || len(added) != 1 {
		t.Fatalf("device limit change should reload the user, deleted=%d added=%d", len(deleted), len(added))
	}
}
