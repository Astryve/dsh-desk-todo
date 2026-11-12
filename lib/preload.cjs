const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('deskTodo', {
  getState: () => ipcRenderer.invoke('desk-todo:get'),
  saveData: (d) => ipcRenderer.invoke('desk-todo:save', d),
  setBounds: (s) => ipcRenderer.send('desk-todo:bounds', s),
  setOpacity: (v) => ipcRenderer.send('desk-todo:opacity', v),
  hide: () => ipcRenderer.send('desk-todo:hide'),
  openData: () => ipcRenderer.send('desk-todo:datafile'),
  onState: (cb) => ipcRenderer.on('desk-todo:state', () => cb()),
  onSound: (cb) => ipcRenderer.on('desk-todo:sound', (_e, urgent) => cb(urgent))
});
