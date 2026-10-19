package sing

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/conf"
	"github.com/sagernet/sing-box/adapter"
	N "github.com/sagernet/sing/common/network"
)

type echoHandler struct {
	sources chan string
	first   chan []byte
}

func (h *echoHandler) NewConnectionEx(ctx context.Context, conn net.Conn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	if h.sources != nil {
		select {
		case h.sources <- metadata.Source.String():
		default:
		}
	}
	if h.first != nil {
		buf := make([]byte, 1)
		if _, err := io.ReadFull(conn, buf); err == nil {
			select {
			case h.first <- buf:
			default:
			}
		}
		_ = conn.Close()
		return
	}
	go func() {
		defer conn.Close()
		_, _ = io.Copy(conn, conn)
	}()
}

func newTestTunnelServer(t *testing.T, mode, password string, handler adapter.ConnectionHandlerEx) (*TunnelServer, int) {
	t.Helper()
	allowDirect := true
	proxyProto := true
	cfg := &conf.TunnelConfig{
		Enable:        true,
		Type:          mode,
		Password:      password,
		WSPath:        "/tunnel",
		AllowDirect:   &allowDirect,
		ProxyProtocol: &proxyProto,
	}
	ts, err := newTunnelServer(context.Background(), "test", "127.0.0.1", 0, cfg, nil, handler)
	if err != nil {
		t.Fatalf("newTunnelServer(%s): %v", mode, err)
	}
	t.Cleanup(func() { _ = ts.Close() })
	return ts, ts.listener.Addr().(*net.TCPAddr).Port
}

func tunnelLibPath(t *testing.T) string {
	t.Helper()
	if p := os.Getenv("NYANPASS_TUNNEL_JS"); p != "" {
		return p
	}
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve test file path")
	}
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "nyanpass", "impl", "lib", "v2bx_tunnel.js")
}

func tunnelClientScriptPath(t *testing.T) string {
	t.Helper()
	if p := os.Getenv("NYANPASS_CLIENT_SCRIPT"); p != "" {
		return p
	}
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve test file path")
	}
	return filepath.Join(filepath.Dir(file), "testdata", "tunnel_client.js")
}

type clientResult struct {
	OK    bool   `json:"ok"`
	Stage string `json:"stage"`
	Error string `json:"error"`
	Echo  string `json:"echo"`
}

func runTunnelClient(t *testing.T, host string, port int, protocol, password string) clientResult {
	t.Helper()
	script := tunnelClientScriptPath(t)
	cmd := exec.Command("node", script, host, fmt.Sprintf("%d", port), protocol, password)
	cmd.Env = append(os.Environ(), "NYANPASS_TUNNEL_JS="+tunnelLibPath(t))
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("node client failed to run: %v\n%s", err, out)
	}
	line := strings.TrimSpace(string(out))
	if idx := strings.LastIndexByte(line, '\n'); idx >= 0 {
		line = line[idx+1:]
	}
	var res clientResult
	if err := json.Unmarshal([]byte(line), &res); err != nil {
		t.Fatalf("bad client output %q: %v", line, err)
	}
	return res
}

func TestV2bXTunnelE2E(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not available")
	}
	password := "e2e-secret-password"
	for _, mode := range []string{"ws", "tls", "wss"} {
		mode := mode
		t.Run(mode, func(t *testing.T) {
			h := &echoHandler{sources: make(chan string, 1)}
			_, port := newTestTunnelServer(t, mode, password, h)

			res := runTunnelClient(t, "127.0.0.1", port, mode, password)
			if !res.OK {
				t.Fatalf("tunnel echo failed: %+v", res)
			}

			select {
			case src := <-h.sources:
				if src != "203.0.113.7:45678" {
					t.Fatalf("real client source not restored, got %q", src)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("handler never observed a connection")
			}
		})
	}
}

func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port
}

func TestV2bXTunnelThroughForwarder(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not available")
	}
	for _, mode := range []string{"ws", "tls", "wss"} {
		mode := mode
		t.Run(mode, func(t *testing.T) {
			h := &echoHandler{sources: make(chan string, 1)}
			_, port := newTestTunnelServer(t, mode, "forwarder-password", h)

			script := filepath.Join(filepath.Dir(tunnelClientScriptPath(t)), "forwarder_client.js")
			implDir := filepath.Join(filepath.Dir(tunnelClientScriptPath(t)), "..", "..", "..", "..", "nyanpass", "impl")
			listenPort := freePort(t)
			cmd := exec.Command("node", script, fmt.Sprintf("%d", listenPort), "127.0.0.1", fmt.Sprintf("%d", port), mode, "forwarder-password")
			cmd.Env = append(os.Environ(),
				"NYANPASS_TUNNEL_JS="+tunnelLibPath(t),
				"NYANPASS_IMPL_DIR="+implDir,
			)
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("forwarder client failed: %v\n%s", err, output)
			}
			var res struct {
				OK         bool   `json:"ok"`
				Stage      string `json:"stage"`
				Error      string `json:"error"`
				Echo       string `json:"echo"`
				ListenPort int    `json:"listen_port"`
				ClientPort int    `json:"client_port"`
			}
			lines := strings.Split(strings.TrimSpace(string(output)), "\n")
			// The connect line comes first, the echo result last; merge them.
			for _, line := range lines {
				var part struct {
					OK         bool   `json:"ok"`
					Stage      string `json:"stage"`
					Error      string `json:"error"`
					Echo       string `json:"echo"`
					ListenPort int    `json:"listen_port"`
					ClientPort int    `json:"client_port"`
				}
				if json.Unmarshal([]byte(strings.TrimSpace(line)), &part) != nil {
					continue
				}
				if part.ListenPort != 0 {
					res.ListenPort = part.ListenPort
				}
				if part.ClientPort != 0 {
					res.ClientPort = part.ClientPort
				}
				if part.Stage == "echo" {
					res.OK = part.OK
					res.Stage = part.Stage
					res.Error = part.Error
					res.Echo = part.Echo
				}
			}
			if !res.OK || res.Stage != "echo" || res.Echo != "FORWARDER-PING" {
				t.Fatalf("forwarder echo failed: %+v\nraw=%s", res, output)
			}
			select {
			case src := <-h.sources:
				want := fmt.Sprintf("127.0.0.1:%d", res.ClientPort)
				if src != want {
					t.Fatalf("forwarder must pass the real client address, got %q want %q", src, want)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("handler never observed a forwarded connection")
			}
		})
	}
}

func TestV2bXTunnelRejectsWrongPassword(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not available")
	}
	h := &echoHandler{sources: make(chan string, 1)}
	_, port := newTestTunnelServer(t, "ws", "correct-password", h)

	res := runTunnelClient(t, "127.0.0.1", port, "ws", "wrong-password")
	if res.OK {
		t.Fatalf("wrong password must not echo, got %+v", res)
	}
	select {
	case src := <-h.sources:
		t.Fatalf("handler must not receive a connection with wrong password, got source %q", src)
	case <-time.After(1200 * time.Millisecond):
	}
}

func TestV2bXTunnelDirectAnyTLSPassthrough(t *testing.T) {
	h := &echoHandler{first: make(chan []byte, 1)}
	_, port := newTestTunnelServer(t, "tls", "direct-password", h)

	// A direct AnyTLS client does a TLS handshake without the v2bx-tunnel ALPN.
	// The tunnel server must hand the untouched ClientHello to the inner inbound.
	dialer := &net.Dialer{Timeout: 2 * time.Second}
	raw, err := dialer.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	client := tls.Client(raw, &tls.Config{InsecureSkipVerify: true})
	_ = client.Handshake() // expected to fail: the handler only sniffs and closes

	select {
	case b := <-h.first:
		if b[0] != 0x16 {
			t.Fatalf("expected TLS ClientHello first byte 0x16, got 0x%02x", b[0])
		}
	case <-time.After(3 * time.Second):
		t.Fatal("direct TLS connection was not dispatched to the inner inbound")
	}
}
