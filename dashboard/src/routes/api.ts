import { Hono } from 'hono'
import { streamSSE } from 'hono/streaming'
import { addClient, removeClient, addHtmlClient, removeHtmlClient } from '../lib/sse.js'
import { getCurrentState } from '../db/poller.js'
import { projectsContent } from '../views/project-card.js'
import { agentsContent } from '../views/agent-row.js'
import { beadTable } from '../views/bead-table.js'
import { escalationsContent } from '../views/escalation-item.js'
import { bugsContent } from '../views/bug-card.js'

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
      for (const panel of ['projects', 'agents', 'beads', 'escalations', 'bugs'] as const) {
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

// GET /api/live — SSE stream sending HTML fragments for HTMX sse-swap
api.get('/live', (c) => {
  return streamSSE(c, async (stream) => {
    const id = Math.random().toString(36).slice(2, 10)

    const writer = (event: string, data: string): Promise<void> =>
      stream.writeSSE({ event, data })

    addHtmlClient(id, writer)

    stream.onAbort(() => {
      removeHtmlClient(id)
    })

    // Send current state as HTML immediately on connect
    const state = getCurrentState()
    if (state) {
      await stream.writeSSE({ event: 'projects', data: projectsContent(state.projects) })
      await stream.writeSSE({ event: 'agents', data: agentsContent(state.agents) })
      await stream.writeSSE({ event: 'beads', data: beadTable(state.beads) })
      await stream.writeSSE({ event: 'escalations', data: escalationsContent(state.escalations) })
      await stream.writeSSE({ event: 'bugs', data: bugsContent(state.bugs) })
    }

    // Heartbeat to keep connection alive
    while (!stream.closed) {
      await stream.sleep(30_000)
      try {
        await stream.writeSSE({ event: 'heartbeat', data: String(Date.now()) })
      } catch {
        break
      }
    }

    removeHtmlClient(id)
  })
})

export { api as apiRoutes }
