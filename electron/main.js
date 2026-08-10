const { app, BrowserWindow, ipcMain, screen } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const EDGE_TRIGGER = 16;
const EDGE_PEEK = 8;
const HIDE_DELAY_MS = 700;
const CURSOR_POLL_MS = 120;
const smokeTest = process.argv.includes('--smoke-test');
if (smokeTest) process.env.MONITOR_PORT = '0';
const { startMonitoringServer, stopMonitoringServer } = require('../server');

let mainWindow;
let monitorServer;
let hideTimer;
let cursorTimer;
let dockSide = null;
let hiddenAtEdge = false;
let animating = false;
let settings = { opacity: 0.94, autoHide: true, alwaysOnTop: true };

function settingsPath() {
  return path.join(app.getPath('userData'), 'window-settings.json');
}

function loadSettings() {
  try {
    settings = { ...settings, ...JSON.parse(fs.readFileSync(settingsPath(), 'utf8')) };
  } catch (error) {
    if (error.code !== 'ENOENT') console.warn(`读取窗口设置失败: ${error.message}`);
  }
}

function saveSettings() {
  fs.writeFileSync(settingsPath(), JSON.stringify(settings, null, 2));
}

function clampOpacity(value) {
  return Math.min(1, Math.max(0.4, Number(value) || 0.94));
}

function windowState() {
  return {
    opacity: settings.opacity,
    autoHide: settings.autoHide,
    alwaysOnTop: mainWindow?.isAlwaysOnTop() ?? settings.alwaysOnTop,
    dockSide,
    hiddenAtEdge
  };
}

function emitState() {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send('window:state', windowState());
  }
}

function displayWorkArea() {
  return screen.getDisplayMatching(mainWindow.getBounds()).workArea;
}

function detectDockSide() {
  if (!mainWindow || animating || hiddenAtEdge) return;
  const bounds = mainWindow.getBounds();
  const work = displayWorkArea();
  let nextSide = null;
  if (bounds.x <= work.x + EDGE_TRIGGER) nextSide = 'left';
  else if (bounds.x + bounds.width >= work.x + work.width - EDGE_TRIGGER) nextSide = 'right';
  else if (bounds.y <= work.y + EDGE_TRIGGER) nextSide = 'top';
  dockSide = nextSide;
  clearTimeout(hideTimer);
  if (dockSide && settings.autoHide) {
    hideTimer = setTimeout(() => hideToEdge(), HIDE_DELAY_MS);
  }
  emitState();
}

function positionsFor(side) {
  const bounds = mainWindow.getBounds();
  const work = displayWorkArea();
  const shown = { x: bounds.x, y: bounds.y };
  const hidden = { x: bounds.x, y: bounds.y };
  if (side === 'left') {
    shown.x = work.x;
    hidden.x = work.x - bounds.width + EDGE_PEEK;
  } else if (side === 'right') {
    shown.x = work.x + work.width - bounds.width;
    hidden.x = work.x + work.width - EDGE_PEEK;
  } else if (side === 'top') {
    shown.y = work.y;
    hidden.y = work.y - bounds.height + EDGE_PEEK;
  }
  return { shown, hidden };
}

function animatePosition(target, onDone) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const start = mainWindow.getBounds();
  const steps = 12;
  let step = 0;
  animating = true;
  const timer = setInterval(() => {
    if (!mainWindow || mainWindow.isDestroyed()) {
      clearInterval(timer);
      return;
    }
    step += 1;
    const progress = 1 - Math.pow(1 - step / steps, 3);
    mainWindow.setPosition(
      Math.round(start.x + (target.x - start.x) * progress),
      Math.round(start.y + (target.y - start.y) * progress),
      false
    );
    if (step >= steps) {
      clearInterval(timer);
      animating = false;
      onDone?.();
      emitState();
    }
  }, 16);
}

function hideToEdge() {
  if (!dockSide || hiddenAtEdge || !settings.autoHide || animating) return;
  const { hidden } = positionsFor(dockSide);
  animatePosition(hidden, () => { hiddenAtEdge = true; });
}

function revealFromEdge() {
  if (!dockSide || !hiddenAtEdge || animating) return;
  const { shown } = positionsFor(dockSide);
  hiddenAtEdge = false;
  animatePosition(shown);
}

function cursorTouchesDock() {
  if (!hiddenAtEdge || !dockSide || !mainWindow) return false;
  const cursor = screen.getCursorScreenPoint();
  const work = displayWorkArea();
  const bounds = mainWindow.getBounds();
  if (dockSide === 'left') return cursor.x <= work.x + EDGE_PEEK && cursor.y >= bounds.y && cursor.y <= bounds.y + bounds.height;
  if (dockSide === 'right') return cursor.x >= work.x + work.width - EDGE_PEEK && cursor.y >= bounds.y && cursor.y <= bounds.y + bounds.height;
  return cursor.y <= work.y + EDGE_PEEK && cursor.x >= bounds.x && cursor.x <= bounds.x + bounds.width;
}

function createWindow(url) {
  loadSettings();
  settings.opacity = clampOpacity(settings.opacity);
  mainWindow = new BrowserWindow({
    width: 920,
    height: 780,
    minWidth: 520,
    minHeight: 520,
    frame: false,
    show: false,
    backgroundColor: '#080a09',
    opacity: settings.opacity,
    alwaysOnTop: settings.alwaysOnTop,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });

  mainWindow.setAlwaysOnTop(settings.alwaysOnTop, 'floating');
  mainWindow.loadURL(url);
  mainWindow.once('ready-to-show', () => {
    if (!smokeTest) mainWindow.show();
  });
  mainWindow.on('move', detectDockSide);
  mainWindow.on('resize', detectDockSide);
  mainWindow.on('closed', () => { mainWindow = null; });
  cursorTimer = setInterval(() => {
    if (cursorTouchesDock()) revealFromEdge();
  }, CURSOR_POLL_MS);

  if (smokeTest) {
    mainWindow.webContents.once('did-finish-load', runDesktopSmokeTest);
  }
}

async function runDesktopSmokeTest() {
  try {
    const result = await mainWindow.webContents.executeJavaScript(`
      new Promise((resolve, reject) => {
        const started = Date.now();
        const timer = setInterval(() => {
          const cards = document.querySelectorAll('.server-card').length;
          const desktop = document.documentElement.classList.contains('desktop');
          const controls = getComputedStyle(document.querySelector('.window-bar')).display !== 'none';
          const settled = cards === 2 && [...document.querySelectorAll('.server-card')]
            .every((card) => !card.classList.contains('is-connecting'));
          if (settled && desktop && controls) {
            clearInterval(timer);
            resolve({ cards, desktop, controls, settled, title: document.title });
          } else if (Date.now() - started > 12000) {
            clearInterval(timer);
            reject(new Error('桌面界面在 12 秒内未完成首次采集'));
          }
        }, 100);
      })
    `);
    await new Promise((resolve) => setTimeout(resolve, 900));
    const artifactDirectory = path.join(__dirname, '..', 'test', 'artifacts');
    fs.mkdirSync(artifactDirectory, { recursive: true });
    const screenshot = await mainWindow.webContents.capturePage();
    fs.writeFileSync(path.join(artifactDirectory, 'electron-window.png'), screenshot.toPNG());
    const originalBounds = mainWindow.getBounds();
    const originalOpacity = settings.opacity;
    const originalAutoHide = settings.autoHide;
    mainWindow.setOpacity(0.8);
    if (Math.abs(mainWindow.getOpacity() - 0.8) > 0.02) throw new Error('透明度 API 验证失败');

    settings.autoHide = true;
    const work = displayWorkArea();
    mainWindow.setPosition(work.x, Math.max(work.y, originalBounds.y), false);
    detectDockSide();
    await new Promise((resolve) => setTimeout(resolve, HIDE_DELAY_MS + 350));
    if (!hiddenAtEdge || dockSide !== 'left') throw new Error('左侧贴边隐藏验证失败');
    revealFromEdge();
    await new Promise((resolve) => setTimeout(resolve, 350));
    if (hiddenAtEdge) throw new Error('贴边唤回验证失败');

    clearTimeout(hideTimer);
    settings.opacity = originalOpacity;
    settings.autoHide = originalAutoHide;
    mainWindow.setOpacity(originalOpacity);
    mainWindow.setBounds(originalBounds, false);
    dockSide = null;
    console.log(`Electron 桌面冒烟测试通过: ${JSON.stringify({ ...result, opacity: true, edgeHide: true })}`);
    app.exit(0);
  } catch (error) {
    console.error(`Electron 桌面冒烟测试失败: ${error.stack || error.message}`);
    app.exit(1);
  }
}

ipcMain.handle('window:get-state', () => windowState());
ipcMain.handle('window:set-opacity', (_event, value) => {
  settings.opacity = clampOpacity(value);
  mainWindow.setOpacity(settings.opacity);
  saveSettings();
  emitState();
  return windowState();
});
ipcMain.handle('window:set-auto-hide', (_event, enabled) => {
  settings.autoHide = Boolean(enabled);
  if (!settings.autoHide && hiddenAtEdge) revealFromEdge();
  saveSettings();
  emitState();
  return windowState();
});
ipcMain.handle('window:toggle-always-on-top', () => {
  settings.alwaysOnTop = !mainWindow.isAlwaysOnTop();
  mainWindow.setAlwaysOnTop(settings.alwaysOnTop, 'floating');
  saveSettings();
  emitState();
  return windowState();
});
ipcMain.on('window:minimize', () => mainWindow.minimize());
ipcMain.on('window:close', () => mainWindow.close());

app.whenReady().then(async () => {
  monitorServer = await startMonitoringServer();
  createWindow(monitorServer.url);
}).catch((error) => {
  console.error(error);
  app.exit(1);
});

app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => {
  clearInterval(cursorTimer);
  clearTimeout(hideTimer);
  stopMonitoringServer();
});
