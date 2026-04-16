import { Hono } from 'hono'
import { pool } from '../db/connection.js'
import { bugsContent } from '../views/bug-card.js'

const bugs = new Hono()

bugs.get('/', async (c) => {
  try {
    const [rows] = await pool.query<any[]>(
      `SELECT id, code_area, bug_title, occurrence_count, status
       FROM victory.bug_memory
       WHERE status IN ('active', 'resolved')
       ORDER BY status ASC, occurrence_count DESC, created_at DESC
       LIMIT 20`,
    )
    return c.html(bugsContent(rows))
  } catch (err) {
    console.error('[bugs route]', err)
    return c.html('<p class="empty error">Unable to load bug patterns</p>')
  }
})

export { bugs as bugsRoutes }
