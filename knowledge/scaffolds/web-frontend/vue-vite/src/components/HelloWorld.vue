<script setup lang="ts">
import { ref } from 'vue'

defineProps<{
  msg: string
}>()

const count = ref(0)
</script>

<template>
  <div class="hello">
    <h2>{{ msg }}</h2>
    <div class="card">
      <button type="button" @click="count++">Count is {{ count }}</button>
      <p>Edit <code>src/components/HelloWorld.vue</code> to test HMR.</p>
    </div>
  </div>
</template>

<style scoped>
.card {
  padding: 2em;
}

button {
  font-size: 1em;
  font-weight: 500;
  font-family: inherit;
  background-color: #1a1a1a;
  color: #ffffff;
  cursor: pointer;
  border-radius: 8px;
  border: 1px solid transparent;
  padding: 0.6em 1.2em;
  transition: border-color 0.25s;
}

button:hover {
  border-color: #42b883;
}
</style>
