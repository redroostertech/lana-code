const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  getAppVersion: () => ipcRenderer.invoke('get-app-version'),
  ping: (message) => ipcRenderer.invoke('ping', message),
  onUpdateMessage: (callback) => {
    ipcRenderer.on('update-message', (_event, value) => callback(value));
  }
});
