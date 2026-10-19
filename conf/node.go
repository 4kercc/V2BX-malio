package conf

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/InazumaV/V2bX/common/json5"
	"github.com/goccy/go-json"
)

type NodeConfig struct {
	ApiConfig ApiConfig `json:"-"`
	Options   Options   `json:"-"`
	// Disabled marks a node that must not be started: startup preparation found
	// something only that node can fix (for example ListenIP=auto whose landing
	// domain does not resolve yet). One broken node must not take the machine's
	// other nodes down with it.
	Disabled       bool   `json:"-"`
	DisabledReason string `json:"-"`
}

type rawNodeConfig struct {
	Include string          `json:"Include"`
	ApiRaw  json.RawMessage `json:"ApiConfig"`
	OptRaw  json.RawMessage `json:"Options"`
}

type ApiConfig struct {
	APIHost      string `json:"ApiHost"`
	NodeID       int    `json:"NodeID"`
	Key          string `json:"ApiKey"`
	NodeType     string `json:"NodeType"`
	PanelType    string `json:"PanelType"`
	Timeout      int    `json:"Timeout"`
	RuleListPath string `json:"RuleListPath"`
}

func (n *NodeConfig) UnmarshalJSON(data []byte) (err error) {
	rn := rawNodeConfig{}
	err = json.Unmarshal(data, &rn)
	if err != nil {
		return err
	}
	if len(rn.Include) != 0 {
		file, _ := strings.CutPrefix(rn.Include, ":")
		switch file {
		case "http", "https":
			rsp, err := http.Get(file)
			if err != nil {
				return err
			}
			defer rsp.Body.Close()
			data, err = io.ReadAll(json5.NewTrimNodeReader(rsp.Body))
			if err != nil {
				return fmt.Errorf("open include file error: %s", err)
			}
		default:
			f, err := os.Open(rn.Include)
			if err != nil {
				return fmt.Errorf("open include file error: %s", err)
			}
			defer f.Close()
			data, err = io.ReadAll(json5.NewTrimNodeReader(f))
			if err != nil {
				return fmt.Errorf("open include file error: %s", err)
			}
		}
		err = json.Unmarshal(data, &rn)
		if err != nil {
			return fmt.Errorf("unmarshal include file error: %s", err)
		}
	}

	n.ApiConfig = ApiConfig{
		APIHost: "http://127.0.0.1",
		Timeout: 30,
	}
	if len(rn.ApiRaw) > 0 {
		err = json.Unmarshal(rn.ApiRaw, &n.ApiConfig)
		if err != nil {
			return
		}
	} else {
		err = json.Unmarshal(data, &n.ApiConfig)
		if err != nil {
			return
		}
	}

		n.Options = Options{
			ListenIP:     "0.0.0.0",
			SendIP:       "0.0.0.0",
			CertConfig:   NewCertConfig(),
			TunnelConfig: NewTunnelConfig(),
		}
	if len(rn.OptRaw) > 0 {
		err = json.Unmarshal(rn.OptRaw, &n.Options)
		if err != nil {
			return
		}
	} else {
		err = json.Unmarshal(data, &n.Options)
		if err != nil {
			return
		}
	}
	return
}

type Options struct {
	Name     string `json:"Name"`
	Core     string `json:"Core"`
	CoreName string `json:"CoreName"`
	ListenIP string `json:"ListenIP"`
	// ListenIP6 is an optional second listen address for the same node, used as
	// an IPv6 (or dual-stack "::") ingress. The node keeps its users, padding,
	// certificate, limits and traffic accounting, and SendIP still decides which
	// source address the traffic leaves with. Write a bare address (:: or
	// 2401:db8::1), never a bracketed value or host:port pair. "auto" picks a
	// free global IPv6 address of this machine.
	ListenIP6              string          `json:"ListenIP6"`
	SendIP                 string          `json:"SendIP"`
	// ListenIPAuto / SendIPAuto record that ListenIP / SendIP were written as
	// "auto" in the configuration file, so the value resolved at startup can be
	// re-derived after a reload instead of being frozen by the first resolution.
	ListenIPAuto bool `json:"-"`
	SendIPAuto   bool `json:"-"`
	DeviceOnlineMinTraffic int64           `json:"DeviceOnlineMinTraffic"`
	LimitConfig            LimitConfig     `json:"LimitConfig"`
	RawOptions             json.RawMessage `json:"RawOptions"`
	XrayOptions            *XrayOptions    `json:"XrayOptions"`
	SingOptions            *SingOptions    `json:"SingOptions"`
		Hysteria2ConfigPath    string          `json:"Hysteria2ConfigPath"`
		CertConfig             *CertConfig     `json:"CertConfig"`
		TunnelConfig           *TunnelConfig   `json:"TunnelConfig"`
		// Soga-compatible flat tunnel fields so operators can also write
		// "TunnelEnable" / "TunnelType" / "TunnelPassword" / "TunnelWSPath"
		// directly inside Options.
		TunnelEnable   bool   `json:"TunnelEnable"`
		TunnelType     string `json:"TunnelType"`
		TunnelPassword string `json:"TunnelPassword"`
		TunnelWSPath   string `json:"TunnelWSPath"`
	}

func (o *Options) UnmarshalJSON(data []byte) error {
	type opt Options
	err := json.Unmarshal(data, (*opt)(o))
	if err != nil {
		return err
	}
	if o.TunnelConfig == nil {
		o.TunnelConfig = NewTunnelConfig()
	}
	if o.TunnelEnable && !o.TunnelConfig.Enable {
		o.TunnelConfig.Enable = true
	}
	if o.TunnelPassword != "" && o.TunnelConfig.Password == "" {
		o.TunnelConfig.Password = o.TunnelPassword
	}
	if o.TunnelType != "" && (o.TunnelConfig.Type == "" || o.TunnelConfig.Type == "ws-tunnel") {
		o.TunnelConfig.Type = o.TunnelType
	}
	if o.TunnelWSPath != "" && (o.TunnelConfig.WSPath == "" || o.TunnelConfig.WSPath == "/tunnel") {
		o.TunnelConfig.WSPath = o.TunnelWSPath
	}
	switch o.Core {
	case "xray":
		o.XrayOptions = NewXrayOptions()
		return json.Unmarshal(data, o.XrayOptions)
	case "sing":
		o.SingOptions = NewSingOptions()
		return json.Unmarshal(data, o.SingOptions)
	case "hysteria2":
		o.RawOptions = data
		return nil
	default:
		o.Core = ""
		o.RawOptions = data
	}
	return nil
}
