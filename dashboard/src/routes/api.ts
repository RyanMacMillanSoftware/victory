import { Hono } from 'hono'
import { streamSSE } from 'hono/streaming'
import { addClient, removeClient } from '../lib/sse.js'
import { getCurrentState } from '../db/poller.js'

const api = new Hono()

// GET /api/state — full dashboard snapshot
api.get('/state', (c) => {
  const state = getCurrentState()
  if (!state) {
    return c.json({ error: 'state not yet available' }, 503)
  }
  return c.json(state)
})

// GET /api/events — SSE stream
// Clients connect once; the poller broadcasts named events per panel.
// HTMX SSE extension maps event names to sse-swap targets.
api.get('/events', (c) => {
  return streamSSE(c, async (stream) => {
    const id = Math.random().toString(36).slice(2, 10)

    const writer = (event: string, data: string): Promise<void> =>
      stream.writeSSE({ event, data })

    addClient(id, writer)

    stream.onAbort(() => {
      removeClient(id)
    })

    // Send initial state snapshot as individual panel events
    const state = getCurrentState()
    if (state) {
      for (const panel of ['projects', 'agents', 'beads', 'escalations'] as const) {
        await stream.writeSSE({ event: panel, data: JSON.stringify(state[panel]) })
      }
    }

    // Heartbeat every 30s to keep connection alive through proxies
    while (!stream.closed) {
      await stream.sleep(30_000)
      try {
        await stream.writeSSE({ event: 'heartbeat', data: String(Date.now()) })
      } catch {
        break
      }
    }

    removeClient(id)
  })
})

export { api as apiRoutes }
