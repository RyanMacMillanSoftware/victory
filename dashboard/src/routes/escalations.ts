import { Hono } from 'hono'
import { getCurrentState } from '../db/poller.js'
import { escalationsContent } from '../views/escalation-item.js'

const escalations = new Hono()

escalations.get('/', (c) => {
  const issues = getCurrentState()?.escalations ?? []
  return c.html(escalationsContent(issues))
})

export { escalations as escalationsRoutes }
