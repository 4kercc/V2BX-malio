'use strict';
// End-to-end tunnel client used by tunnel_e2e_test.go.
// Usage: node tunnel_client.js <host> <port> <protocol> <password>
// Prints a single JSON line describing the result.

const crypto = require('crypto');

const libPath = process.env.NYANPASS_TUNNEL_JS ||
  require('path').join(__dirname, '..', '..', '..', '..', 'nyanpass', 'impl', 'lib', 'v2bx_tunnel.js');

const { dialV2bXTunnel } = require(libPath);

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

async function main() {
  const [host, portStr, protocol, password] = process.argv.slice(2);
  const port = Number(portStr);
  const nonce = crypto.randomBytes(8).toString('hex');
  const payload = Buffer.from('PING:' + nonce, 'utf8');

  let stream;
  try {
    stream = await dialV2bXTunnel({
      host,
      port,
      protocol,
      password,
      wsPath: '/ws',
      sni: host,
      insecure: true,
      clientInfo: {
        srcIp: '203.0.113.7',
        srcPort: 45678,
        dstIp: '198.51.100.9',
        dstPort: port,
      },
    });
  } catch (e) {
    out({ ok: false, stage: 'dial', error: e.message });
    process.exit(0);
  }

  let received = Buffer.alloc(0);
  const timer = setTimeout(() => {
    out({ ok: false, stage: 'read', error: 'timeout', echo: received.toString('utf8') });
    try { stream.destroy(); } catch { /* ignore */ }
    process.exit(0);
  }, 4000);

  stream.on('data', (d) => {
    received = Buffer.concat([received, d]);
    if (received.length >= payload.length) {
      clearTimeout(timer);
      out({ ok: received.equals(payload), stage: 'read', echo: received.toString('utf8') });
      try { stream.destroy(); } catch { /* ignore */ }
      process.exit(0);
    }
  });
  stream.on('error', (e) => {
    clearTimeout(timer);
    out({ ok: false, stage: 'stream', error: e.message });
    process.exit(0);
  });
  stream.on('close', () => {
    clearTimeout(timer);
    out({ ok: false, stage: 'close', error: 'closed before echo', echo: received.toString('utf8') });
    process.exit(0);
  });

  stream.write(payload);
}

main().catch((e) => {
  out({ ok: false, stage: 'exception', error: e && e.message ? e.message : String(e) });
  process.exit(0);
});
