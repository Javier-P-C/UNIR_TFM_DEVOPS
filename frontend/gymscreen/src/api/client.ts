// Local development sets VITE_API_URL in .env.local (backend on another port).
// Container builds leave it unset: the Gateway serves the frontend and the
// API on the same origin, so one image works in every environment.
const API_URL = import.meta.env.VITE_API_URL ?? '/api/v1'

export async function apiGet<T>(path: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(`${API_URL}${path}`, {
    signal,
    headers: { Accept: 'application/json' },
  })
  if (!response.ok) {
    throw new Error(`Error ${response.status} al consultar ${path}`)
  }
  return response.json() as Promise<T>
}
