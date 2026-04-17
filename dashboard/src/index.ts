import { Hono } from 'hono'
import { serveStatic } from 'hono/bun'
import { layout } from './views/layout.js'
import { apiRoutes } from './routes/api.js'
import { projectsRoutes } from './routes/projects.js'
import { agentsRoutes } from './routes/agents.js'
import { beadsRoutes } from './routes/beads.js'
import { escalationsRoutes } from './routes/escalations.js'
import { bugsRoutes } from './routes/bugs.js'
import { convoysRoutes } from './routes/convoys.js'
import { polecatsRoutes } from './routes/polecats.js'
import { startPoller } from './db/poller.js'

const app = new Hono()

app.use('/public/*', serveStatic({ root: './' }))

app.route('/api', apiRoutes)
app.route('/routes/projects', projectsRoutes)
app.route('/routes/agents', agentsRoutes)
app.route('/routes/beads', beadsRoutes)
app.route('/routes/escalations', escalationsRoutes)
app.route('/routes/bugs', bugsRoutes)
app.route('/routes/convoys', convoysRoutes)
app.route('/routes/polecats', polecatsRoutes)

app.get('/', (c) => {
  return c.html(
    layout('Dashboard', `
      <div hx-ext="sse" sse-connect="/api/live">
        <section class="dashboard-grid">
          <div class="panel" id="panel-projects">
            <h2>Projects</h2>
            <div id="panel-projects-content"
                 hx-get="/routes/projects" hx-trigger="load" hx-swap="innerHTML"
                 sse-swap="projects" hx-target="#panel-projects-content">
              <p class="empty">Loading\u2026</p>
            </div>
          </div>
          <div class="panel" id="panel-agents">
            <h2>Agents</h2>
            <div id="panel-agents-content"
                 hx-get="/routes/agents" hx-trigger="load" hx-swap="innerHTML"
                 sse-swap="agents" hx-target="#panel-agents-content">
              <p class="empty">Loading\u2026</p>
            </div>
          </div>
          <div class="panel" id="panel-beads">
            <h2>Beads</h2>
            <div id="panel-beads-content"
                 hx-get="/routes/beads" hx-trigger="load" hx-swap="innerHTML"
                 sse-swap="beads" hx-target="#panel-beads-content">
              <p class="empty">Loading\u2026</p>
            </div>
          </div>
          <div class="panel" id="panel-escalations">
            <h2>Escalations</h2>
            <div id="panel-escalations-content"
                 hx-get="/routes/escalations" hx-trigger="load" hx-swap="innerHTML"
                 sse-swap="escalations" hx-target="#panel-escalations-content">
              <p class="empty">Loading\u2026</p>
            </div>
          </div>
          <div class="panel" id="panel-bugs">
            <h2>Bugs</h2>
            <div id="panel-bugs-content"
                 hx-get="/routes/bugs" hx-trigger="load" hx-swap="innerHTML"
                 sse-swap="bugs" hx-target="#panel-bugs-content">
              <p class="empty">Loading\u2026</p>
            </div>
          </div>
          <div class="panel" id="panel-convoys">
            <h2>Convoys</h2>
            <div id="panel-convoys-content"
                 hx-get="/routes/convoys" hx-trigger="load" hx-swap="innerHTML"
                 sse-swap="convoys" hx-target="#panel-convoys-content">
              <p class="empty">Loading\u2026</p>
            </div>
          </div>
          <div class="panel" id="panel-polecats">
            <h2>Polecats</h2>
            <div id="panel-polecats-content"
                 hx-get="/routes/polecats" hx-trigger="load" hx-swap="innerHTML"
                 sse-swap="polecats" hx-target="#panel-polecats-content">
              <p class="empty">Loading\u2026</p>
            </div>
          </div>
        </section>
      </div>
    `)
  )
})

const PORT = Number(process.env.DASHBOARD_PORT ?? process.env.PORT ?? 3456)

export default {
  port: PORT,
  fetch: app.fetch,
}

startPoller()
console.log(`Victory dashboard listening on http://localhost:${PORT}`)
