package sing

import (
	"bufio"
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	stdtls "crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/InazumaV/V2bX/conf"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/log"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	tunnelMagic          = "VT01"
	tunnelSaltLen        = 16
	tunnelTagLen         = 16
	tunnelMaxPayload     = 16384
	tunnelMaxTimeSkewSec = 300
	tunnelFlagProxyV2    = 0x01
	// tunnelNextProto is a standard ALPN value: the outer TLS ClientHello must not
	// carry a product-specific marker (a custom "v2bx-tunnel" ALPN is trivially
	// fingerprinted). Tunnel traffic is recognised after the handshake — by the WS
	// path in wss mode, or by the AEAD handshake itself (VT01) in tls mode.
	tunnelNextProto = "http/1.1"
	// tunnelLegacyALPN is accepted only for upstream clients deployed before
	// v1.4.2 (they offer "v2bx-tunnel"). The server never advertises its ALPN
	// list to clients (TLS 1.3 keeps the selection encrypted), and the current
	// client never sends this value, so it adds no observable fingerprint to
	// either side's ClientHello. Remove once every entry runs v1.4.2+.
	tunnelLegacyALPN = "v2bx-tunnel"
	wsGUID          = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	// tunnelDefaultWSPath looks like an ordinary WebSocket endpoint rather than a
	// distinctive one.
	tunnelDefaultWSPath = "/ws"
)

var (
	tunnelDirC2S  = []byte{'C', '2', 'S', 0}
	tunnelDirS2C  = []byte{'S', '2', 'C', 0}
	tunnelInfoC2S = []byte("v2bx-tunnel-v1-c2s\x01")
	tunnelInfoS2C = []byte("v2bx-tunnel-v1-s2c\x01")
	pp2Sig        = []byte{0x0d, 0x0a, 0x0d, 0x0a, 0x00, 0x0d, 0x0a, 0x51, 0x55, 0x49, 0x54, 0x0a}
)

// httpNotFoundResponse is the stock Go http.NotFound body, used both for
// non-matching WS paths and for plain HTTPS probes on a tls-mode tunnel port:
// the endpoint answers like an ordinary web server instead of resetting.
const httpNotFoundResponse = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 19\r\nConnection: close\r\n\r\n404 page not found\n"

// looksLikeHTTPRequest reports whether the first four bytes start an HTTP
// request line. Used after the outer TLS handshake to spot browser/probe
// traffic (the tunnel's first bytes are a random 16-byte salt instead).
func looksLikeHTTPRequest(head []byte) bool {
	if len(head) < 4 {
		return false
	}
	switch string(head[:4]) {
	case "GET ", "POST", "HEAD", "PUT ", "OPTI", "PRI ", "DELE", "PATC", "CONN", "TRAC":
		return true
	}
	return false
}

// deriveTunnelKeys derives 16-byte AES-128-GCM keys for client->server and
// server->client using RFC 5869 HKDF-SHA256 (matching nyanpass v2bx_tunnel.js).
func deriveTunnelKeys(password string, salt []byte) (c2sKey, s2cKey []byte, err error) {
	if len(salt) != tunnelSaltLen {
		return nil, nil, errors.New("invalid tunnel salt length")
	}
	mac := hmac.New(sha256.New, salt)
	mac.Write([]byte(password))
	prk := mac.Sum(nil)

	macC2S := hmac.New(sha256.New, prk)
	macC2S.Write(tunnelInfoC2S)
	c2sKey = macC2S.Sum(nil)[:16]

	macS2C := hmac.New(sha256.New, prk)
	macS2C.Write(tunnelInfoS2C)
	s2cKey = macS2C.Sum(nil)[:16]
	return c2sKey, s2cKey, nil
}

func makeTunnelNonce(dirPrefix []byte, seq uint64) [12]byte {
	var nonce [12]byte
	copy(nonce[0:4], dirPrefix[0:4])
	binary.BigEndian.PutUint64(nonce[4:12], seq)
	return nonce
}

// aeadTunnelConn implements net.Conn over an underlying transport (WS or TLS)
// with AES-128-GCM authenticated framing.
type aeadTunnelConn struct {
	net.Conn
	readAEAD   cipher.AEAD
	writeAEAD  cipher.AEAD
	readSeq    uint64
	writeSeq   uint64
	readBuf    bytes.Buffer
	readMu     sync.Mutex
	writeMu    sync.Mutex
	remoteAddr net.Addr
	localAddr  net.Addr
}

func newServerAEADTunnelConn(raw net.Conn, password string) (*aeadTunnelConn, byte, error) {
	var salt [tunnelSaltLen]byte
	if _, err := io.ReadFull(raw, salt[:]); err != nil {
		return nil, 0, fmt.Errorf("read tunnel salt: %w", err)
	}
	c2sKey, s2cKey, err := deriveTunnelKeys(password, salt[:])
	if err != nil {
		return nil, 0, err
	}
	readBlock, err := aes.NewCipher(c2sKey)
	if err != nil {
		return nil, 0, err
	}
	readAEAD, err := cipher.NewGCM(readBlock)
	if err != nil {
		return nil, 0, err
	}
	writeBlock, err := aes.NewCipher(s2cKey)
	if err != nil {
		return nil, 0, err
	}
	writeAEAD, err := cipher.NewGCM(writeBlock)
	if err != nil {
		return nil, 0, err
	}

	tc := &aeadTunnelConn{
		Conn:       raw,
		readAEAD:   readAEAD,
		writeAEAD:  writeAEAD,
		remoteAddr: raw.RemoteAddr(),
		localAddr:  raw.LocalAddr(),
	}

	// Frame #0 must be the authenticated handshake frame ("VT01" + timestamp + flags + padding)
	hsPlain, err := tc.readOneFrame()
	if err != nil {
		return nil, 0, fmt.Errorf("tunnel handshake decrypt failed (wrong password?): %w", err)
	}
	flags, err := verifyHandshakePlaintext(hsPlain)
	if err != nil {
		return nil, 0, err
	}
	return tc, flags, nil
}

func verifyHandshakePlaintext(plain []byte) (byte, error) {
	if len(plain) < 14 {
		return 0, errors.New("tunnel handshake frame too short")
	}
	if string(plain[0:4]) != tunnelMagic {
		return 0, errors.New("invalid tunnel magic")
	}
	ts := int64(binary.BigEndian.Uint64(plain[4:12]))
	now := time.Now().Unix()
	diff := now - ts
	if diff < 0 {
		diff = -diff
	}
	if diff > tunnelMaxTimeSkewSec {
		return 0, fmt.Errorf("tunnel handshake timestamp expired (skew=%ds)", diff)
	}
	flags := plain[12]
	padLen := int(plain[13])
	if len(plain) != 14+padLen {
		return 0, errors.New("invalid tunnel handshake padding")
	}
	return flags, nil
}

func (c *aeadTunnelConn) readOneFrame() ([]byte, error) {
	var lenBuf [2]byte
	if _, err := io.ReadFull(c.Conn, lenBuf[:]); err != nil {
		return nil, err
	}
	plainLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	if plainLen > tunnelMaxPayload {
		return nil, fmt.Errorf("tunnel frame payload overflow: %d", plainLen)
	}
	cipherAndTag := make([]byte, plainLen+tunnelTagLen)
	if _, err := io.ReadFull(c.Conn, cipherAndTag); err != nil {
		return nil, err
	}
	nonce := makeTunnelNonce(tunnelDirC2S, c.readSeq)
	c.readSeq++
	plain, err := c.readAEAD.Open(cipherAndTag[:0], nonce[:], cipherAndTag, lenBuf[:])
	if err != nil {
		return nil, err
	}
	return plain, nil
}

func (c *aeadTunnelConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for c.readBuf.Len() == 0 {
		plain, err := c.readOneFrame()
		if err != nil {
			return 0, err
		}
		if len(plain) > 0 {
			c.readBuf.Write(plain)
		}
	}
	return c.readBuf.Read(p)
}

func (c *aeadTunnelConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	total := 0
	for len(p) > 0 {
		chunk := p
		if len(chunk) > tunnelMaxPayload {
			chunk = p[:tunnelMaxPayload]
		}
		p = p[len(chunk):]

		var lenBuf [2]byte
		binary.BigEndian.PutUint16(lenBuf[:], uint16(len(chunk)))
		nonce := makeTunnelNonce(tunnelDirS2C, c.writeSeq)
		c.writeSeq++

		frame := make([]byte, 2, 2+len(chunk)+tunnelTagLen)
		copy(frame[0:2], lenBuf[:])
		frame = c.writeAEAD.Seal(frame, nonce[:], chunk, lenBuf[:])

		if _, err := writeFull(c.Conn, frame); err != nil {
			return total, err
		}
		total += len(chunk)
	}
	return total, nil
}

func (c *aeadTunnelConn) RemoteAddr() net.Addr {
	if c.remoteAddr != nil {
		return c.remoteAddr
	}
	return c.Conn.RemoteAddr()
}

func (c *aeadTunnelConn) LocalAddr() net.Addr {
	if c.localAddr != nil {
		return c.localAddr
	}
	return c.Conn.LocalAddr()
}

func writeFull(w io.Writer, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := w.Write(buf[total:])
		if n > 0 {
			total += n
		}
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// wsServerConn implements net.Conn over an upgraded RFC 6455 WebSocket stream.
type wsServerConn struct {
	net.Conn
	reader  *bufio.Reader
	readBuf bytes.Buffer
	readMu  sync.Mutex
	writeMu sync.Mutex
}

func newWSServerConn(conn net.Conn, br *bufio.Reader) *wsServerConn {
	return &wsServerConn{
		Conn:   conn,
		reader: br,
	}
}

func (w *wsServerConn) Read(p []byte) (int, error) {
	w.readMu.Lock()
	defer w.readMu.Unlock()
	for w.readBuf.Len() == 0 {
		var hdr [2]byte
		if _, err := io.ReadFull(w.reader, hdr[:]); err != nil {
			return 0, err
		}
		opcode := hdr[0] & 0x0f
		masked := (hdr[1] & 0x80) != 0
		payloadLen := uint64(hdr[1] & 0x7f)
		switch payloadLen {
		case 126:
			var ext [2]byte
			if _, err := io.ReadFull(w.reader, ext[:]); err != nil {
				return 0, err
			}
			payloadLen = uint64(binary.BigEndian.Uint16(ext[:]))
		case 127:
			var ext [8]byte
			if _, err := io.ReadFull(w.reader, ext[:]); err != nil {
				return 0, err
			}
			payloadLen = binary.BigEndian.Uint64(ext[:])
		}
		if payloadLen > 4*1024*1024 {
			return 0, errors.New("ws frame too large")
		}
		var maskKey [4]byte
		if masked {
			if _, err := io.ReadFull(w.reader, maskKey[:]); err != nil {
				return 0, err
			}
		}
		payload := make([]byte, payloadLen)
		if _, err := io.ReadFull(w.reader, payload); err != nil {
			return 0, err
		}
		if masked {
			for i := range payload {
				payload[i] ^= maskKey[i&3]
			}
		}
		switch opcode {
		case 0x08: // close
			return 0, io.EOF
		case 0x09: // ping -> pong
			_ = w.writeFrame(0x0a, payload)
		case 0x0a: // pong
		default:
			if len(payload) > 0 {
				w.readBuf.Write(payload)
			}
		}
	}
	return w.readBuf.Read(p)
}

func (w *wsServerConn) writeFrame(opcode byte, payload []byte) error {
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	l := len(payload)
	var head []byte
	if l < 126 {
		head = []byte{0x80 | opcode, byte(l)}
	} else if l < 65536 {
		head = make([]byte, 4)
		head[0] = 0x80 | opcode
		head[1] = 126
		binary.BigEndian.PutUint16(head[2:4], uint16(l))
	} else {
		head = make([]byte, 10)
		head[0] = 0x80 | opcode
		head[1] = 127
		binary.BigEndian.PutUint64(head[2:10], uint64(l))
	}
	frame := make([]byte, len(head)+l)
	copy(frame, head)
	copy(frame[len(head):], payload)
	_, err := writeFull(w.Conn, frame)
	return err
}

func (w *wsServerConn) Write(p []byte) (int, error) {
	if err := w.writeFrame(0x02, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// rewindConn prepends already-peeked bytes in front of a net.Conn.
type rewindConn struct {
	net.Conn
	reader io.Reader
}

func newRewindConn(c net.Conn, r io.Reader) net.Conn {
	return &rewindConn{Conn: c, reader: r}
}

func (r *rewindConn) Read(p []byte) (int, error) {
	return r.reader.Read(p)
}

// parseProxyProtocolV2 reads a PROXY protocol v2 header from the stream and
// returns the real client source address if valid.
func parseProxyProtocolV2(r io.Reader) (M.Socksaddr, error) {
	var hdr [16]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return M.Socksaddr{}, err
	}
	if !bytes.Equal(hdr[0:12], pp2Sig) {
		return M.Socksaddr{}, errors.New("invalid proxy protocol v2 signature")
	}
	verCmd := hdr[12]
	if (verCmd >> 4) != 2 {
		return M.Socksaddr{}, errors.New("unsupported proxy protocol version")
	}
	fam := hdr[13]
	extLen := int(binary.BigEndian.Uint16(hdr[14:16]))
	if extLen > 2048 {
		return M.Socksaddr{}, errors.New("proxy protocol header too long")
	}
	ext := make([]byte, extLen)
	if _, err := io.ReadFull(r, ext); err != nil {
		return M.Socksaddr{}, err
	}
	cmd := verCmd & 0x0f
	if cmd != 0x01 { // LOCAL command
		return M.Socksaddr{}, nil
	}
	switch fam {
	case 0x11, 0x12: // IPv4 TCP/UDP
		if len(ext) < 12 {
			return M.Socksaddr{}, errors.New("short ipv4 proxy header")
		}
		var ip4 [4]byte
		copy(ip4[:], ext[0:4])
		srcPort := binary.BigEndian.Uint16(ext[8:10])
		return M.SocksaddrFrom(netip.AddrFrom4(ip4), srcPort), nil
	case 0x21, 0x22: // IPv6 TCP/UDP
		if len(ext) < 36 {
			return M.Socksaddr{}, errors.New("short ipv6 proxy header")
		}
		var ip6 [16]byte
		copy(ip6[:], ext[0:16])
		srcPort := binary.BigEndian.Uint16(ext[32:34])
		return M.SocksaddrFrom(netip.AddrFrom16(ip6), srcPort), nil
	default:
		return M.Socksaddr{}, nil
	}
}

// TunnelServer manages the encrypted tunnel listener for a single node ingress.
type TunnelServer struct {
	ctx        context.Context
	tag        string
	listenAddr string
	cfg        *conf.TunnelConfig
	certCfg    *conf.CertConfig
	tlsConf    *stdtls.Config
	handler    adapter.ConnectionHandlerEx
	listener   net.Listener
	closed     atomic.Bool
}

func buildTunnelTLSConfig(certCfg *conf.CertConfig) (*stdtls.Config, error) {
	var cert stdtls.Certificate
	var err error
	if certCfg != nil && certCfg.CertFile != "" && certCfg.KeyFile != "" {
		cert, err = stdtls.LoadX509KeyPair(certCfg.CertFile, certCfg.KeyFile)
		if err != nil {
			// The outer TLS layer only wraps the already AEAD-authenticated tunnel;
			// a missing/rotating certificate must not keep the node down.
			log.Warn(fmt.Sprintf("tunnel: load certificate %s failed, falling back to self-signed: %s", certCfg.CertFile, err))
			cert, err = generateSelfSignedCert()
		}
	} else {
		cert, err = generateSelfSignedCert()
	}
	if err != nil {
		return nil, err
	}
	return &stdtls.Config{
		Certificates: []stdtls.Certificate{cert},
		// Only standard ALPN values are advertised: an ordinary HTTPS endpoint.
		// HTTP/1.1 is what our WS client speaks, so the server does not advertise
		// h2 (which it cannot serve). The legacy token is accepted for old
		// upstream clients only; Go negotiates by the client's preference order,
		// so updated clients (h2+http/1.1) still land on http/1.1.
		NextProtos: []string{tunnelNextProto, tunnelLegacyALPN},
	}, nil
}

func generateSelfSignedCert() (stdtls.Certificate, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return stdtls.Certificate{}, err
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: "v2bx-tunnel"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		return stdtls.Certificate{}, err
	}
	return stdtls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  priv,
	}, nil
}

func newTunnelServer(
	ctx context.Context,
	tag string,
	listenIP string,
	port uint16,
	cfg *conf.TunnelConfig,
	certCfg *conf.CertConfig,
	handler adapter.ConnectionHandlerEx,
) (*TunnelServer, error) {
	addr, err := netip.ParseAddr(listenIP)
	if err != nil {
		return nil, fmt.Errorf("invalid tunnel listen ip %s: %w", listenIP, err)
	}
	network := "tcp"
	if addr.Is4() {
		network = "tcp4"
	} else if addr.Is6() && !addr.IsUnspecified() {
		network = "tcp6"
	}
	bindAddr := net.JoinHostPort(addr.String(), fmt.Sprintf("%d", port))
	ln, err := net.Listen(network, bindAddr)
	if err != nil {
		return nil, err
	}
	var tlsConf *stdtls.Config
	mode := normalizeTunnelMode(cfg.Type)
	if mode == "tls" || mode == "wss" {
		tlsConf, err = buildTunnelTLSConfig(certCfg)
		if err != nil {
			_ = ln.Close()
			return nil, fmt.Errorf("build tunnel tls config: %w", err)
		}
		if cfg.AllowsDirect() {
			log.Warn(fmt.Sprintf("Node %s: tunnel mode %s terminates the outer TLS on this port; plain AnyTLS clients cannot share it (AllowDirect is honoured in ws mode only)", tag, mode))
		}
	}
	s := &TunnelServer{
		ctx:        ctx,
		tag:        tag,
		listenAddr: bindAddr,
		cfg:        cfg,
		certCfg:    certCfg,
		tlsConf:    tlsConf,
		handler:    handler,
		listener:   ln,
	}
	go s.acceptLoop()
	return s, nil
}

func normalizeTunnelMode(t string) string {
	s := strings.ToLower(strings.TrimSpace(t))
	switch s {
	case "tls", "tls-tunnel":
		return "tls"
	case "wss", "ws-tls", "ws-tls-tunnel":
		return "wss"
	default:
		return "ws"
	}
}

func normalizeTunnelPath(p string) string {
	s := strings.TrimSpace(p)
	if s == "" {
		return tunnelDefaultWSPath
	}
	if !strings.HasPrefix(s, "/") {
		return "/" + s
	}
	return s
}

func (s *TunnelServer) Close() error {
	s.closed.Store(true)
	if s.listener != nil {
		return s.listener.Close()
	}
	return nil
}

func (s *TunnelServer) acceptLoop() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			if s.closed.Load() {
				return
			}
			continue
		}
		go s.handleConn(conn)
	}
}

func (s *TunnelServer) handleConn(rawConn net.Conn) {
	_ = rawConn.SetDeadline(time.Now().Add(12 * time.Second))
	br := bufio.NewReaderSize(rawConn, 4096)
	peek, err := br.Peek(3)
	if err != nil {
		_ = rawConn.Close()
		return
	}

	mode := normalizeTunnelMode(s.cfg.Type)
	isHTTP := (peek[0] == 'G' && peek[1] == 'E' && peek[2] == 'T') ||
		(peek[0] == 'P' && peek[1] == 'O' && peek[2] == 'S') ||
		(peek[0] == 'H' && peek[1] == 'E' && peek[2] == 'A')
	isTLS := peek[0] == 0x16 && peek[1] == 0x03

	// 1) Plain HTTP / WebSocket upgrade on the port
	if isHTTP {
		wsConn, ok := s.upgradeWebSocket(rawConn, br)
		if !ok {
			return
		}
		s.serveEncryptedTunnel(wsConn, rawConn)
		return
	}

	// 2) TLS ClientHello on the port
	if isTLS {
		rewound := newRewindConn(rawConn, br)
		// In WS tunnel mode no outer TLS is used: a ClientHello is a direct AnyTLS client
		if mode == "ws" {
			if s.cfg.AllowsDirect() {
				_ = rawConn.SetDeadline(time.Time{})
				s.dispatchToAnyTLS(rewound, M.SocksaddrFromNet(rawConn.RemoteAddr()).Unwrap(), M.SocksaddrFromNet(rawConn.LocalAddr()).Unwrap())
				return
			}
			_ = rawConn.Close()
			return
		}

		// tls / wss mode: the outer TLS is terminated here and the AEAD handshake
		// authenticates the peer. No ALPN marker is used to tell tunnel traffic from
		// direct traffic — the ClientHello carries only standard ALPN (http/1.1),
		// so it is indistinguishable from an ordinary HTTPS client. Direct AnyTLS
		// coexistence is therefore supported in ws mode only (AllowDirect).
		tlsConn := stdtls.Server(rewound, s.tlsConf)
		if err := tlsConn.Handshake(); err != nil {
			log.Warn(fmt.Sprintf("Node %s: tunnel outer TLS handshake failed from %s (mode=%s): %s", s.tag, rawConn.RemoteAddr(), mode, err))
			_ = tlsConn.Close()
			return
		}
		if proto := tlsConn.ConnectionState().NegotiatedProtocol; proto == tunnelLegacyALPN {
			log.Warn(fmt.Sprintf("Node %s: legacy %q ALPN from %s — upstream client predates v1.4.2, please update it", s.tag, tunnelLegacyALPN, rawConn.RemoteAddr()))
		}
		tlsBr := bufio.NewReaderSize(tlsConn, 4096)
		if mode == "wss" {
			wsConn, ok := s.upgradeWebSocket(tlsConn, tlsBr)
			if !ok {
				return
			}
			s.serveEncryptedTunnel(wsConn, rawConn)
			return
		}
		// tls mode: answer plain HTTPS probes with a normal 404 page so that the
		// port behaves like an ordinary web server instead of resetting the socket.
		head, err := tlsBr.Peek(4)
		if err != nil {
			_ = tlsConn.Close()
			return
		}
		if looksLikeHTTPRequest(head) {
			_ = rawConn.SetDeadline(time.Now().Add(3 * time.Second))
			_, _ = writeFull(tlsConn, []byte(httpNotFoundResponse))
			_ = tlsConn.Close()
			return
		}
		s.serveEncryptedTunnel(newRewindConn(tlsConn, tlsBr), rawConn)
		return
	}

	// 3) Any other traffic
	if s.cfg.AllowsDirect() {
		_ = rawConn.SetDeadline(time.Time{})
		rewound := newRewindConn(rawConn, br)
		s.dispatchToAnyTLS(rewound, M.SocksaddrFromNet(rawConn.RemoteAddr()).Unwrap(), M.SocksaddrFromNet(rawConn.LocalAddr()).Unwrap())
		return
	}
	_ = rawConn.Close()
}

func (s *TunnelServer) upgradeWebSocket(conn net.Conn, br *bufio.Reader) (net.Conn, bool) {
	req, err := http.ReadRequest(br)
	if err != nil {
		_ = conn.Close()
		return nil, false
	}
	wantPath := normalizeTunnelPath(s.cfg.WSPath)
	if req.Method != http.MethodGet ||
		req.URL.Path != wantPath ||
		!strings.EqualFold(req.Header.Get("Upgrade"), "websocket") {
		// Mirror soga_tunnel behavior: non-matching HTTP probes get standard 404
		_, _ = conn.Write([]byte(httpNotFoundResponse))
		_ = conn.Close()
		return nil, false
	}
	wsKey := strings.TrimSpace(req.Header.Get("Sec-WebSocket-Key"))
	if wsKey == "" {
		_ = conn.Close()
		return nil, false
	}
	sum := sha1.Sum([]byte(wsKey + wsGUID))
	accept := base64.StdEncoding.EncodeToString(sum[:])
	resp := fmt.Sprintf(
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		accept,
	)
	if _, err := writeFull(conn, []byte(resp)); err != nil {
		_ = conn.Close()
		return nil, false
	}
	return newWSServerConn(conn, br), true
}

func (s *TunnelServer) serveEncryptedTunnel(transportConn net.Conn, rawTCP net.Conn) {
	aeadConn, flags, err := newServerAEADTunnelConn(transportConn, s.cfg.Password)
	if err != nil {
		log.Warn(fmt.Sprintf("Node %s: reject tunnel connection from %s: %s", s.tag, rawTCP.RemoteAddr(), err))
		_ = transportConn.Close()
		return
	}

	source := M.SocksaddrFromNet(rawTCP.RemoteAddr()).Unwrap()
	dest := M.SocksaddrFromNet(rawTCP.LocalAddr()).Unwrap()

	if (flags&tunnelFlagProxyV2) != 0 && s.cfg.AcceptsProxyProtocol() {
		realSrc, err := parseProxyProtocolV2(aeadConn)
		if err != nil {
			log.Warn(fmt.Sprintf("Node %s: tunnel PROXY v2 parse failed from %s: %s", s.tag, rawTCP.RemoteAddr(), err))
			_ = aeadConn.Close()
			return
		}
		if realSrc.IsValid() {
			source = realSrc
			aeadConn.remoteAddr = realSrc.TCPAddr()
		}
	}

	log.Info(fmt.Sprintf("Node %s: %s tunnel connection from %s, real client %s",
		s.tag, normalizeTunnelMode(s.cfg.Type), rawTCP.RemoteAddr(), source))

	_ = rawTCP.SetDeadline(time.Time{})
	s.dispatchToAnyTLS(aeadConn, source, dest)
}

func (s *TunnelServer) dispatchToAnyTLS(conn net.Conn, source M.Socksaddr, dest M.Socksaddr) {
	var metadata adapter.InboundContext
	metadata.Source = source
	metadata.OriginDestination = dest
	ctx := log.ContextWithNewID(s.ctx)
	s.handler.NewConnectionEx(ctx, conn, metadata, nil)
}
