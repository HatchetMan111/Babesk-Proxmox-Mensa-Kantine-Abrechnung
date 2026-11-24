// Dünner API-Client für das babesk-Backend.
// Passe die Endpunkte an die tatsächlichen babesk-Routen an (code/ im Repo).
export async function login(username, password) {
  const res = await fetch('/api/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password })
  })
  if (!res.ok) throw new Error(`Login fehlgeschlagen (HTTP ${res.status})`)
  return res.json()
}

export async function getMenu() {
  const res = await fetch('/api/menu')
  if (!res.ok) throw new Error(`Menü nicht ladbar (HTTP ${res.status})`)
  return res.json()
}
