// Dünner API-Client. Token liegt in localStorage, wird als Bearer gesendet.
const TOKEN_KEY = 'babesk_token'

export function getToken() { return localStorage.getItem(TOKEN_KEY) }
export function setToken(t) { t ? localStorage.setItem(TOKEN_KEY, t) : localStorage.removeItem(TOKEN_KEY) }

async function req(path, opts = {}) {
  const headers = { ...(opts.headers || {}) }
  if (opts.body) headers['Content-Type'] = 'application/json'
  const t = getToken()
  if (t) headers['Authorization'] = 'Bearer ' + t
  const res = await fetch('/api' + path, { ...opts, headers })
  if (res.status === 401) { setToken(null); throw new Error('Nicht eingeloggt') }
  if (!res.ok) {
    let msg = `HTTP ${res.status}`
    try { const j = await res.json(); msg = j.detail || msg } catch {}
    throw new Error(msg)
  }
  return res.status === 204 ? null : res.json()
}

export const api = {
  login: (username, password) => req('/login', { method: 'POST', body: JSON.stringify({ username, password }) }),
  me: () => req('/me'),
  menu: (days = 7) => req('/menu?days=' + days),
  orders: () => req('/orders'),
  order: (meal_id) => req('/orders', { method: 'POST', body: JSON.stringify({ meal_id }) }),
  cancel: (id) => req('/orders/' + id, { method: 'DELETE' }),
  cards: () => req('/cards'),
}