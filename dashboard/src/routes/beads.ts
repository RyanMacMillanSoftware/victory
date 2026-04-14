import { Hono } from 'hono'
import { getCurrentState } from '../db/poller.js'
import { beadTable } from '../views/bead-table.js'

const beads = new Hono()

beads.get('/', (c) => {
  const issues = getCurrentState()?.beads ?? []
  return c.html(beadTable(issues))
})

export { beads as beadsRoutes }
