import { describe, it, expect, mock, beforeAll } from 'bun:test'
import { Hono } from 'hono'

mock.module('../db/poller.js', () => ({
  getCurrentState: () => ({
    projects: [],
    agents: [],
    beads: [],
    escalations: [],
    bugs: [],
    convoys: [],
    polecats: [],
    timestamp: 0,
  }),
  startPoller: () => {},
}))

mock.module('../db/connection.js', () => ({
  pool: {
    query: async () => [[], []],
  },
}))

mock.module('node:fs/promises', () => ({
  readdir: async () => [],
  readFile: async () => '{}',
}))

let app: Hono

beforeAll(async () => {
  const { projectsRoutes } = await import('../routes/projects.js')
  const { agentsRoutes } = await import('../routes/agents.js')
  const { beadsRoutes } = await import('../routes/beads.js')
  const { escalationsRoutes } = await import('../routes/escalations.js')
  const { bugsRoutes } = await import('../routes/bugs.js')
  const { convoysRoutes } = await import('../routes/convoys.js')
  const { polecatsRoutes } = await import('../routes/polecats.js')

  app = new Hono()

  app.get('/', (c) => c.html('<html><body><h1>Dashboard</h1></body></html>'))
  app.route('/routes/projects', projectsRoutes)
  app.route('/routes/agents', agentsRoutes)
  app.route('/routes/beads', beadsRoutes)
  app.route('/routes/escalations', escalationsRoutes)
  app.route('/routes/bugs', bugsRoutes)
  app.route('/routes/convoys', convoysRoutes)
  app.route('/routes/polecats', polecatsRoutes)
})

const routes = [
  '/',
  '/routes/projects',
  '/routes/agents',
  '/routes/beads',
  '/routes/escalations',
  '/routes/bugs',
  '/routes/convoys',
  '/routes/polecats',
]

describe('route handlers', () => {
  for (const path of routes) {
    it(`GET ${path} returns 200 with HTML`, async () => {
      const res = await app.request(path)
      expect(res.status).toBe(200)
      const contentType = res.headers.get('content-type') ?? ''
      expect(contentType).toContain('text/html')
    })
  }
})
