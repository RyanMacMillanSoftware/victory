import { Hono } from 'hono'
import { serveStatic } from 'hono/bun'
import { layout } from './views/layout.js'

const app = new Hono()

app.use('/public/*', serveStatic({ root: './' }))

app.get('/', (c) => {
  return c.html(
    layout('Dashboard', `
      <section class="dashboard-grid">
        <div class="panel" id="projects">
          <h2>Projects</h2>
          <p class="empty">Loading…</p>
        </div>
        <div class="panel" id="agents">
          <h2>Agents</h2>
          <p class="empty">Loading…</p>
        </div>
        <div class="panel" id="beads">
          <h2>Beads</h2>
          <p class="empty">Loading…</p>
        </div>
        <div class="panel" id="escalations">
          <h2>Escalations</h2>
          <p class="empty">Loading…</p>
        </div>
      </section>
    `)
  )
})

const PORT = 3456

export default {
  port: PORT,
  fetch: app.fetch,
}

console.log(`Victory dashboard listening on http://localhost:${PORT}`)
