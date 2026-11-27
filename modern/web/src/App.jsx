import { useEffect, useState } from 'react'
import { api, getToken, setToken } from './api.js'

const WDU = new Intl.DateTimeFormat('de-DE', { weekday: 'long', day: '2-digit', month: '2-digit' })
const EUR = new Intl.NumberFormat('de-DE', { style: 'currency', currency: 'EUR' })

function fmtDate(iso) {
  const d = new Date(iso + 'T00:00:00')
  return WDU.format(d)
}

export default function App() {
  const [user, setUser] = useState(null)
  const [menu, setMenu] = useState(null)
  const [orders, setOrders] = useState([])
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  async function loadAll() {
    const [me, m, o] = await Promise.all([api.me(), api.menu(7), api.orders()])
    setUser(me); setMenu(m); setOrders(o)
  }

  useEffect(() => {
    if (getToken()) loadAll().catch(() => setToken(null))
  }, [])

  async function handleLogin(e) {
    e.preventDefault(); setErr(''); setBusy(true)
    const f = new FormData(e.target)
    try {
      const r = await api.login(f.get('username'), f.get('password'))
      setToken(r.token); await loadAll()
    } catch (e) { setErr(e.message) } finally { setBusy(false) }
  }

  async function order(mealId) {
    setErr(''); setBusy(true)
    try {
      const r = await api.order(mealId)
      setUser(u => ({ ...u, credit: r.credit }))
      await loadAll()
    } catch (e) { setErr(e.message) } finally { setBusy(false) }
  }

  async function cancel(id) {
    setErr(''); setBusy(true)
    try { await api.cancel(id); await loadAll() }
    catch (e) { setErr(e.message) } finally { setBusy(false) }
  }

  function logout() { setToken(null); setUser(null); setMenu(null); setOrders([]) }

  if (!user) {
    return (
      <div className="login-wrap">
        <form className="card login" onSubmit={handleLogin}>
          <h1>babesk<span className="dot">.</span></h1>
          <p className="sub">Mensa-Bestellung</p>
          <input name="username" placeholder="Benutzername" autoComplete="username" required />
          <input name="password" type="password" placeholder="Passwort" autoComplete="current-password" required />
          <button disabled={busy}>{busy ? '…' : 'Anmelden'}</button>
          {err && <p className="err">{err}</p>}
        </form>
      </div>
    )
  }

  const orderedToday = new Set(orders.map(o => o.meal_id))

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">babesk<span className="dot">.</span></div>
        <div className="who">
          <span className="credit">{EUR.format(user.credit)}</span>
          <span className="name">{user.forename || user.name || user.username}</span>
          <button className="ghost" onClick={logout}>Abmelden</button>
        </div>
      </header>

      {err && <p className="err banner">{err}</p>}

      <main>
        <h2>Speiseplan</h2>
        {menu && menu.length === 0 && <p className="muted">Diese Woche sind noch keine Menüs hinterlegt.</p>}
        {menu?.map(day => (
          <section key={day.date} className="day">
            <h3>{fmtDate(day.date)}</h3>
            <div className="meals">
              {day.meals.map(m => (
                <article key={m.id} className="meal">
                  <div className="meal-main">
                    <h4>{m.name}</h4>
                    {m.description && <p className="desc">{m.description}</p>}
                    <div className="meta">
                      <span className="price">{m.price != null ? EUR.format(m.price) : '–'}</span>
                      <span className="left">{m.remaining} frei</span>
                    </div>
                  </div>
                  {m.ordered
                    ? <span className="badge ok">Bestellt</span>
                    : <button className="primary" disabled={busy || m.remaining <= 0} onClick={() => order(m.id)}>
                        {m.remaining <= 0 ? 'Ausverkauft' : 'Bestellen'}
                      </button>}
                </article>
              ))}
            </div>
          </section>
        ))}

        {orders.length > 0 && (
          <section className="day">
            <h3>Meine Bestellungen</h3>
            <ul className="orders">
              {orders.map(o => (
                <li key={o.id}>
                  <span className="o-date">{fmtDate(o.date)}</span>
                  <span className="o-name">{o.name}</span>
                  <span className="o-price">{o.price != null ? EUR.format(o.price) : ''}</span>
                  {o.fetched
                    ? <span className="badge muted">Abgeholt</span>
                    : <button className="ghost sm" disabled={busy} onClick={() => cancel(o.id)}>Stornieren</button>}
                </li>
              ))}
            </ul>
          </section>
        )}
      </main>
    </div>
  )
}