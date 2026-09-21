// preload.cjs — 暴露收快照/字号/尺寸上报与退出
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('overlay', {
  onSnapshot: (cb) => ipcRenderer.on('snapshot', (_e, s) => cb(s)),
  onInit: (cb) => ipcRenderer.on('overlay:init', (_e, v) => cb(v)),
  onScale: (cb) => ipcRenderer.on('overlay:scale', (_e, v) => cb(v)),
  resize: (sz) => ipcRenderer.send('overlay:resize', sz),
  setScale: (s) => ipcRenderer.send('overlay:scale', s),
  quit: () => ipcRenderer.invoke('overlay:quit'),
});
