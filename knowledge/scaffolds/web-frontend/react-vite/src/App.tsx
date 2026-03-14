import { useState } from 'react'
import './App.css'

function App() {
  const [count, setCount] = useState(0)

  return (
    <div className="app">
      <h1>My React App</h1>
      <div className="card">
        <button onClick={() => setCount((c) => c + 1)}>
          Count is {count}
        </button>
        <p>Edit <code>src/App.tsx</code> and save to test HMR.</p>
      </div>
    </div>
  )
}

export default App
