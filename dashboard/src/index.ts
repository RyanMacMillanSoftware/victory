import { Hono } from 'hono'
import { serveStatic } from 'hono/bun'
import { layout } from './views/layout.js'
import { apiRoutes } from './routes/api.js'
import { projectsRoutes } from './routes/projects.js'
import { agentsRoutes } from './routes/agents.js'
import { beadsRoutes } from './routes/beads.js'
import { escalationsRoutes } from './routes/escalations.js'
import { bugsRoutes } from './routes/bugs.js'
import { startPoller } from './db/poller.js'

const app = new Hono()

app.use('/public/*', serveStatic({ root: './' }))

app.route('/api', apiRoutes)
app.route('/routes/projects', projectsRoutes)
app.route('/routes/agents', agentsRoutes)
app.route('/routes/beads', beadsRoutes)
app.route('/routes/escalations', escalationsRoutes)
app.route('/routes/bugs', bugsRoutes)

app.get('/', (c) => {
  return c.html(
    layout('Dashboard', `
      <div hx-ext="sse" sse-connect="/api/live">
        <section class="dashboard-grid">
          <div class="panel" id="panel-projects"
               hx-get="/routes/projects" hx-trigger="load" hx-swap="innerHTML"
               sse-swap="projects" hx-target="#panel-projects">
            <p class="empty">Loading\u2026</p>
          </div>
          <div class="panel" id="panel-agents"
               hx-get="/routes/agents" hx-trigger="load" hx-swap="innerHTML"
               sse-swap="agents" hx-target="#panel-agents">
            <p class="empty">Loading\u2026</p>
          </div>
          <div class="panel" id="panel-beads"
               hx-get="/routes/beads" hx-trigger="load" hx-swap="innerHTML"
               sse-swap="beads" hx-target="#panel-beads">
            <p class="empty">Loading\u2026</p>
          </div>
          <div class="panel" id="panel-escalations"
               hx-get="/routes/escalations" hx-trigger="load" hx-swap="innerHTML"
               sse-swap="escalations" hx-target="#panel-escalations">
            <p class="empty">Loading\u2026</p>
          </div>
          <div class="panel" id="panel-bugs"
               hx-get="/routes/bugs" hx-trigger="load" hx-swap="innerHTML">
            <p class="empty">Loading\u2026</p>
          </div>
        </section>
      </div>
    `)
  )
})

const PORT = 3456

export default {
  port: PORT,
  fetch: app.fetch,
}

startPoller()
console.log(`Victory dashboard listening on http://localhost:${PORT}`)
