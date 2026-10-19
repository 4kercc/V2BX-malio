'use strict';
// End-to-end: nyanpass Forwarder (entry agent) -> V2bX encrypted tunnel.
// Usage: node forwarder_client.js <listenPort> <v2bxHost> <v2bxPort> <protocol> <password>
// Prints one JSON line with the forwarder listen port and its own client port.

const net = require('net');
const path = require('path');

const implDir = process.env.NYANPASS_IMPL_DIR ||
  path.join(__dirname, '..', '..', '..', '..', 'nyanpass', 'impl');
const { Forwarder } = require(path.join(implDir, 'agent', 'forwarder.js'));

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

async function main() {
  const [listenPortStr, v2bxHost, v2bxPortStr, protocol, password] = process.argv.slice(2);
  const listenPort = Number(listenPortStr);
  const v2bxPort = Number(v2bxPortStr);

  const fwd = new Forwarder({ log: () => {} });
  fwd.apply({
    rules: [{
      id: 1,
      role: 'listen',
      direct: true,
      listen_port: listenPort,
      protocol,
      target: `${v2bxHost}:${v2bxPort}`,
      proxy_protocol: true,
      tunnel_password: password,
      tunnel_type: protocol,
      tunnel_ws_path: '/tunnel',
      speed_limit: 0,
      connection_limit: 0,
      ip_limit: 0,
      state: 'Normal',
      next: null,
    }],
  });

  const srv = fwd.listeners.get(1);
  if (!srv) {
    out({ ok: false, error: 'forwarder listener not created' });
    process.exit(0);
  }
  await new Promise((resolve, reject) => {
    if (srv.listening) return resolve();
    srv.once('listening', resolve);
    srv.once('error', reject);
    setTimeout(() => reject(new Error('forwarder listen timeout')), 3000);
  });

  const payload = Buffer.from('FORWARDER-PING', 'utf8');
  const client = net.connect({ host: '127.0.0.1', port: listenPort }, () => {
    out({ ok: true, stage: 'connected', listen_port: listenPort, client_port: client.localPort });
    client.write(payload);
  });
  client.setTimeout(5000, () => {
    out({ ok: false, stage: 'timeout', listen_port: listenPort, client_port: client.localPort });
    process.exit(0);
  });
  let received = Buffer.alloc(0);
  client.on('data', (d) => {
    received = Buffer.concat([received, d]);
    if (received.length >= payload.length) {
      out({ ok: received.equals(payload), stage: 'echo', echo: received.toString('utf8') });
      client.destroy();
      fwd.close();
      process.exit(0);
    }
  });
  client.on('error', (e) => {
    out({ ok: false, stage: 'client', error: e.message });
    process.exit(0);
  });
}

main().catch((e) => {
  out({ ok: false, stage: 'exception', error: e && e.message ? e.message : String(e) });
  process.exit(0);
});
