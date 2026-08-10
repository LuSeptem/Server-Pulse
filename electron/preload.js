const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('monitorWindow', {
  isDesktop: true,
  getState: () => ipcRenderer.invoke('window:get-state'),
  setOpacity: (value) => ipcRenderer.invoke('window:set-opacity', value),
  setAutoHide: (enabled) => ipcRenderer.invoke('window:set-auto-hide', enabled),
  toggleAlwaysOnTop: () => ipcRenderer.invoke('window:toggle-always-on-top'),
  minimize: () => ipcRenderer.send('window:minimize'),
  close: () => ipcRenderer.send('window:close'),
  onState: (callback) => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('window:state', listener);
    return () => ipcRenderer.removeListener('window:state', listener);
  }
});

