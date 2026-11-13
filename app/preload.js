const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('widget', {
  getState: () => ipcRenderer.invoke('get-state'),
  saveData: (d) => ipcRenderer.invoke('save-data', d),
  setIgnore: (v) => ipcRenderer.send('set-ignore', v),
  setBounds: (s) => ipcRenderer.send('set-bounds', s),
  setOpacity: (v) => ipcRenderer.send('set-opacity', v),
  hide: () => ipcRenderer.send('hide-widget'),
  openData: () => ipcRenderer.send('open-data'),
  reload: () => ipcRenderer.send('reload'),
  onState: (cb) => ipcRenderer.on('state', (_e, d) => cb(d)),
  onFlash: (cb) => ipcRenderer.on('flash', (_e, p) => cb(p))
});
