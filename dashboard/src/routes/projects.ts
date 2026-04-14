import { Hono } from 'hono'
import { getCurrentState } from '../db/poller.js'
import { projectsContent } from '../views/project-card.js'

const projects = new Hono()

projects.get('/', (c) => {
  const issues = getCurrentState()?.projects ?? []
  return c.html(projectsContent(issues))
})

export { projects as projectsRoutes }
