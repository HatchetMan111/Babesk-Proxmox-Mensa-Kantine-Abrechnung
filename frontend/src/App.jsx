import { useState } from 'react'
import { login, getMenu } from './api.js'

export default function App() {
  const [user, setUser] = useState(null)
  const [menu, setMenu] = useState(null)
  const [error, setError] = useState('')

  async function handleLogin(e) {
    e.preventDefault()
    setError('')
    const f = new FormData(e.target)
    try {
      const u = await login(f.get('username'), f.get('password'))
      setUser(u)
      setMenu(await getMenu())
    } catch (err) {
      setError(err.message)
    }
  }

  if (!user) {
    return (
      <main style={{ fontFamily: 'sans-serif', maxWidth: 360, margin: '4rem auto' }}>
        <h1>babesk</h1>
        <p>Bargeldloses Bestellsystem für Schulkantinen</p>
        <form onSubmit={handleLogin}>
          <p><input name="username" placeholder="Benutzername" required /></p>
          <p><input name="password" type="password" placeholder="Passwort" required /></p>
          <button type="submit">Anmelden</button>
        </form>
        {error && <p style={{ color: 'red' }}>{error}</p>}
      </main>
    )
  }

  return (
    <main style={{ fontFamily: 'sans-serif', maxWidth: 640, margin: '2rem auto' }}>
      <h1>Speiseplan</h1>
      <p>Angemeldet als: {user.username ?? user.name ?? 'Unbekannt'}</p>
      <pre>{JSON.stringify(menu, null, 2)}</pre>
    </main>
  )
}
