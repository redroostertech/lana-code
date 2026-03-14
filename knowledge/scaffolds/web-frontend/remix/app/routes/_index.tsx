import type { MetaFunction } from '@remix-run/node'

export const meta: MetaFunction = () => {
  return [
    { title: 'My Remix App' },
    { name: 'description', content: 'Welcome to Remix!' },
  ]
}

export default function Index() {
  return (
    <main style={{ fontFamily: 'Inter, system-ui, sans-serif', padding: '2rem' }}>
      <h1>Welcome to My Remix App</h1>
      <p>
        Get started by editing <code>app/routes/_index.tsx</code>.
      </p>
      <ul>
        <li>
          <a href="https://remix.run/docs" target="_blank" rel="noreferrer">
            Remix Docs
          </a>
        </li>
      </ul>
    </main>
  )
}
