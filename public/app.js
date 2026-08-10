const grid = document.querySelector('#server-grid');
const template = document.querySelector('#server-template');
const connection = document.querySelector('#connection-status');
const histories = new Map();
const snapshots = new Map();
const cards = new Map();
const MAX_HISTORY = 12;

async function initializeWindowControls() {
  if (!window.monitorWindow?.isDesktop) return;
  document.documentElement.classList.add('desktop');
  const opacity = document.querySelector('#window-opacity');
  const opacityValue = document.querySelector('#window-opacity-value');
  const edge = document.querySelector('#window-edge');
  const pin = document.querySelector('#window-pin');

  const renderState = (state) => {
    opacity.value = Math.round(state.opacity * 100);
    opacityValue.value = `${opacity.value}%`;
    edge.classList.toggle('is-active', state.autoHide);
    edge.setAttribute('aria-pressed', String(state.autoHide));
    pin.classList.toggle('is-active', state.alwaysOnTop);
    pin.setAttribute('aria-pressed', String(state.alwaysOnTop));
  };

  renderState(await window.monitorWindow.getState());
  window.monitorWindow.onState(renderState);
  opacity.addEventListener('input', () => { opacityValue.value = `${opacity.value}%`; });
  opacity.addEventListener('change', async () => renderState(await window.monitorWindow.setOpacity(Number(opacity.value) / 100)));
  edge.addEventListener('click', async () => {
    const active = edge.getAttribute('aria-pressed') !== 'true';
    renderState(await window.monitorWindow.setAutoHide(active));
  });
  pin.addEventListener('click', async () => renderState(await window.monitorWindow.toggleAlwaysOnTop()));
  document.querySelector('#window-minimize').addEventListener('click', () => window.monitorWindow.minimize());
  document.querySelector('#window-close').addEventListener('click', () => window.monitorWindow.close());
}

function clamp(value) {
  return Math.min(100, Math.max(0, Number(value) || 0));
}

function formatPercent(value) {
  return Number.isFinite(value) ? `${Math.round(value)}%` : '—';
}

function formatMemory(mib) {
  if (!Number.isFinite(mib)) return '—';
  return mib >= 1024 ? `${(mib / 1024).toFixed(1)} GB` : `${Math.round(mib)} MB`;
}

function formatUptime(seconds) {
  if (!Number.isFinite(seconds)) return '—';
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  return days > 0 ? `${days}D ${hours}H` : `${hours}H ${Math.floor((seconds % 3600) / 60)}M`;
}

function setMeter(element, value) {
  const bounded = clamp(value);
  element.style.width = `${bounded}%`;
  element.style.background = bounded >= 90 ? 'var(--danger)' : bounded >= 75 ? 'var(--orange)' : 'var(--acid)';
}

function createCard(snapshot) {
  const card = template.content.firstElementChild.cloneNode(true);
  card.dataset.serverId = snapshot.id;
  card.querySelector('.node-id').textContent = `NODE / ${snapshot.id.toUpperCase()}`;
  card.querySelector('.node-label').textContent = snapshot.label;
  grid.append(card);
  cards.set(snapshot.id, card);
  return card;
}

function pushHistory(snapshot) {
  if (snapshot.status !== 'online' || !snapshot.metrics) return;
  const history = histories.get(snapshot.id) || [];
  const gpuValues = snapshot.metrics.gpus.map((gpu) => gpu.utilization).filter(Number.isFinite);
  history.push({
    cpu: clamp(snapshot.metrics.cpu.utilization),
    memory: clamp(snapshot.metrics.memory.percent),
    gpu: gpuValues.length ? gpuValues.reduce((sum, value) => sum + value, 0) / gpuValues.length : 0
  });
  if (history.length > MAX_HISTORY) history.shift();
  histories.set(snapshot.id, history);
}

function points(history, key) {
  if (history.length === 1) history = [history[0], history[0]];
  return history.map((point, index) => {
    const x = index * (600 / Math.max(1, history.length - 1));
    const y = 86 - clamp(point[key]) * .8;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');
}

function renderChart(card, history) {
  const svg = card.querySelector('.sparkline');
  const gridLines = [10, 50, 90].map((y) => `<line class="grid-line" x1="0" y1="${y}" x2="600" y2="${y}"/>`).join('');
  if (!history.length) {
    svg.innerHTML = gridLines;
    return;
  }
  svg.innerHTML = `${gridLines}
    <polyline class="cpu-line" points="${points(history, 'cpu')}"/>
    <polyline class="memory-line" points="${points(history, 'memory')}"/>
    <polyline class="gpu-line" points="${points(history, 'gpu')}"/>`;
}

function addGpuStat(row, label, value) {
  const stat = document.createElement('div');
  stat.className = 'gpu-stat';
  const caption = document.createElement('span');
  const strong = document.createElement('strong');
  caption.textContent = label;
  strong.textContent = value;
  stat.append(caption, strong);
  row.append(stat);
}

function renderGpus(card, gpus) {
  const list = card.querySelector('.gpu-list');
  list.replaceChildren();
  if (!gpus.length) {
    const empty = document.createElement('div');
    empty.className = 'gpu-empty';
    empty.textContent = '未检测到 NVIDIA GPU 或 nvidia-smi 不可用';
    list.append(empty);
    return;
  }
  for (const gpu of gpus) {
    const row = document.createElement('div');
    row.className = 'gpu-row';
    const name = document.createElement('div');
    name.className = 'gpu-name';
    const index = document.createElement('span');
    const title = document.createElement('strong');
    index.textContent = `GPU ${gpu.index ?? '—'}`;
    title.textContent = gpu.name;
    name.append(index, title);
    row.append(name);
    addGpuStat(row, 'UTIL', formatPercent(gpu.utilization));
    addGpuStat(row, 'VRAM', `${formatMemory(gpu.memoryUsedMiB)} / ${formatMemory(gpu.memoryTotalMiB)}`);
    addGpuStat(row, 'TEMP / POWER', `${gpu.temperatureC ?? '—'}°C · ${gpu.powerDrawW ?? '—'}W`);
    list.append(row);
  }
}

function renderCard(snapshot, recordHistory = true) {
  snapshots.set(snapshot.id, snapshot);
  const card = cards.get(snapshot.id) || createCard(snapshot);
  card.classList.remove('is-connecting', 'is-online', 'is-offline');
  card.classList.add(`is-${snapshot.status}`);
  card.querySelector('.node-state span').textContent = snapshot.status;
  card.querySelector('.latency').textContent = snapshot.latencyMs == null ? '— ms' : `${snapshot.latencyMs} ms`;

  const offline = card.querySelector('.offline-message');
  if (snapshot.status === 'offline') {
    offline.hidden = false;
    offline.textContent = snapshot.error || '无法连接服务器';
  } else {
    offline.hidden = true;
  }

  if (snapshot.metrics) {
    const metrics = snapshot.metrics;
    card.querySelector('.hostname').textContent = `${metrics.hostname} · SSH ${snapshot.host}`;
    card.querySelector('.cpu-gauge strong').textContent = formatPercent(metrics.cpu.utilization);
    card.querySelector('.memory-gauge strong').textContent = formatPercent(metrics.memory.percent);
    card.querySelector('.memory-detail').textContent = `${formatMemory(metrics.memory.usedMiB)} / ${formatMemory(metrics.memory.totalMiB)}`;
    setMeter(card.querySelector('.cpu-gauge .meter i'), metrics.cpu.utilization);
    setMeter(card.querySelector('.memory-gauge .meter i'), metrics.memory.percent);
    card.querySelector('.load-average').textContent = `LOAD ${metrics.load.one} / ${metrics.load.five} / ${metrics.load.fifteen}`;
    card.querySelector('.uptime').textContent = `UP ${formatUptime(metrics.uptimeSeconds)}`;
    renderGpus(card, metrics.gpus);
  }
  if (recordHistory) pushHistory(snapshot);
  renderChart(card, histories.get(snapshot.id) || []);
  renderSummary();
}

function renderSummary() {
  const values = [...snapshots.values()];
  const online = values.filter((snapshot) => snapshot.status === 'online');
  const gpuCount = online.reduce((sum, snapshot) => sum + (snapshot.metrics?.gpus.length || 0), 0);
  const latest = values.map((snapshot) => snapshot.checkedAt).filter(Boolean).sort().at(-1);
  document.querySelector('#online-count').textContent = `${online.length} / ${values.length}`;
  document.querySelector('#gpu-count').textContent = online.length ? String(gpuCount) : '—';
  document.querySelector('#last-update').textContent = latest ? new Date(latest).toLocaleTimeString('zh-CN', { hour12: false }) : '等待数据';
}

function setConnection(state, label) {
  connection.dataset.state = state;
  connection.querySelector('strong').textContent = label;
}

async function bootstrap() {
  try {
    const response = await fetch('/api/servers');
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    document.querySelector('#poll-rate').textContent = `${payload.pollIntervalMs / 1000} 秒`;
    payload.servers.forEach((snapshot) => renderCard(snapshot, false));

    const events = new EventSource('/api/events');
    events.addEventListener('open', () => setConnection('online', '实时流已连接'));
    events.addEventListener('snapshot', (event) => renderCard(JSON.parse(event.data)));
    events.addEventListener('error', () => setConnection('offline', '正在重新连接'));
  } catch (error) {
    setConnection('offline', '控制面不可用');
    grid.textContent = `无法加载监控数据：${error.message}`;
  }
}

initializeWindowControls();
bootstrap();
