const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { loadConfig } = require('./src/config');
const { collectServer } = require('./src/collector');

const config = loadConfig();
const publicDirectory = path.join(__dirname, 'public');
const clients = new Set();
const polling = new Set();
const snapshots = new Map(config.servers.map((server) => [server.id, {
  id: server.id,
  label: server.label,
  host: server.host,
  status: 'connecting',
  checkedAt: null,
  latencyMs: null,
  metrics: null,
  error: null
}]));

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml'
};

function sendJson(response, status, body) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  response.end(JSON.stringify(body));
}

function broadcast(snapshot) {
  const packet = `event: snapshot\ndata: ${JSON.stringify(snapshot)}\n\n`;
  for (const client of clients) client.write(packet);
}

async function poll(server) {
  if (polling.has(server.id)) return;
  polling.add(server.id);
  try {
    const result = await collectServer(server.host, config.sshTimeoutMs);
    const snapshot = {
      id: server.id,
      label: server.label,
      host: server.host,
      status: 'online',
      checkedAt: new Date().toISOString(),
      latencyMs: result.latencyMs,
      metrics: result.metrics,
      error: null
    };
    snapshots.set(server.id, snapshot);
    broadcast(snapshot);
  } catch (error) {
    const previous = snapshots.get(server.id);
    const snapshot = {
      ...previous,
      status: 'offline',
      checkedAt: new Date().toISOString(),
      latencyMs: null,
      error: error.message
    };
    snapshots.set(server.id, snapshot);
    broadcast(snapshot);
  } finally {
    polling.delete(server.id);
  }
}

function serveStatic(requestPath, response) {
  const relativePath = requestPath === '/' ? 'index.html' : requestPath.slice(1);
  const filePath = path.resolve(publicDirectory, relativePath);
  if (!filePath.startsWith(`${publicDirectory}${path.sep}`)) {
    sendJson(response, 403, { error: 'Forbidden' });
    return;
  }
  fs.readFile(filePath, (error, data) => {
    if (error) {
      sendJson(response, error.code === 'ENOENT' ? 404 : 500, { error: 'Not found' });
      return;
    }
    response.writeHead(200, {
      'Content-Type': mimeTypes[path.extname(filePath)] || 'application/octet-stream',
      'Cache-Control': 'no-cache'
    });
    response.end(data);
  });
}

const server = http.createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || 'localhost'}`);
  if (request.method === 'GET' && url.pathname === '/api/servers') {
    sendJson(response, 200, { pollIntervalMs: config.pollIntervalMs, servers: [...snapshots.values()] });
    return;
  }
  if (request.method === 'GET' && url.pathname === '/api/events') {
    response.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive'
    });
    response.write('retry: 2000\n\n');
    clients.add(response);
    request.on('close', () => clients.delete(response));
    return;
  }
  if (request.method === 'GET') {
    serveStatic(decodeURIComponent(url.pathname), response);
    return;
  }
  sendJson(response, 405, { error: 'Method not allowed' });
});

let interval = null;

function startMonitoringServer() {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(config.port, config.bind, () => {
      server.removeListener('error', reject);
      const address = server.address();
      const activePort = typeof address === 'object' ? address.port : config.port;
      console.log(`Server Pulse 已启动：http://${config.bind}:${activePort}`);
      for (const target of config.servers) poll(target);
      interval = setInterval(() => {
        for (const target of config.servers) poll(target);
      }, config.pollIntervalMs);
      resolve({
        url: `http://${config.bind}:${activePort}`,
        close: stopMonitoringServer
      });
    });
  });
}

function stopMonitoringServer() {
  if (interval) {
    clearInterval(interval);
    interval = null;
  }
  for (const client of clients) client.end();
  return new Promise((resolve) => {
    if (!server.listening) {
      resolve();
      return;
    }
    server.close(resolve);
  });
}

if (require.main === module) {
  startMonitoringServer().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
  const shutdown = () => stopMonitoringServer().then(() => process.exit(0));
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

module.exports = { startMonitoringServer, stopMonitoringServer };
