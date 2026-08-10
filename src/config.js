const fs = require('node:fs');
const path = require('node:path');

const HOST_PATTERN = /^[a-zA-Z0-9._-]+$/;

function loadConfig(configPath = path.join(__dirname, '..', 'config', 'servers.json')) {
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

  if (!Array.isArray(config.servers) || config.servers.length === 0) {
    throw new Error('config.servers 必须是非空数组');
  }

  const ids = new Set();
  for (const server of config.servers) {
    if (!server.id || !server.label || !server.host) {
      throw new Error('每台服务器都必须配置 id、label 和 host');
    }
    if (!HOST_PATTERN.test(server.host)) {
      throw new Error(`SSH 主机别名不安全: ${server.host}`);
    }
    if (ids.has(server.id)) {
      throw new Error(`服务器 id 重复: ${server.id}`);
    }
    ids.add(server.id);
  }

  return {
    port: Number(process.env.MONITOR_PORT || config.port || 4173),
    bind: process.env.MONITOR_BIND || config.bind || '127.0.0.1',
    pollIntervalMs: Number(config.pollIntervalMs || 5000),
    sshTimeoutMs: Number(config.sshTimeoutMs || 8000),
    servers: config.servers
  };
}

module.exports = { loadConfig };

