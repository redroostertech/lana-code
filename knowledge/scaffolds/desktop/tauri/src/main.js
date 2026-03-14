import { invoke } from '@tauri-apps/api/core';

const greetForm = document.getElementById('greet-form');
const greetInput = document.getElementById('greet-input');
const greetOutput = document.getElementById('greet-output');

greetForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const name = greetInput.value.trim();
  if (!name) return;

  try {
    const message = await invoke('greet', { name });
    greetOutput.textContent = message;
  } catch (err) {
    greetOutput.textContent = `Error: ${err}`;
  }
});
