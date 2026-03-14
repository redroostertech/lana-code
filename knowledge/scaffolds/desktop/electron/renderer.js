async function init() {
  // Display app version from main process
  const version = await window.electronAPI.getAppVersion();
  document.getElementById('version').textContent = `v${version}`;

  // IPC ping demo
  const pingBtn = document.getElementById('ping-btn');
  const pingInput = document.getElementById('ping-input');
  const pingResult = document.getElementById('ping-result');

  pingBtn.addEventListener('click', async () => {
    const message = pingInput.value || 'hello';
    const response = await window.electronAPI.ping(message);
    pingResult.textContent = response;
  });

  // Listen for messages from main process
  window.electronAPI.onUpdateMessage((message) => {
    console.log('Message from main:', message);
  });
}

init();
