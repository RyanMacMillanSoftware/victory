import { Hono } from 'hono'
import { getCurrentState } from '../db/poller.js'
import { agentsContent } from '../views/agent-row.js'

const agents = new Hono()

agents.get('/', (c) => {
  const issues = getCurrentState()?.agents ?? []
  return c.html(agentsContent(issues))
})

export { agents as agentsRoutes }
