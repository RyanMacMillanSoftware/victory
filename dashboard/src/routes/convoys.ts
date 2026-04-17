import { Hono } from 'hono'
import { pool } from '../db/connection.js'
import { convoysContent } from '../views/convoy-row.js'

const convoys = new Hono()

convoys.get('/', async (c) => {
  try {
    const [rows] = await pool.query<any[]>(
      `SELECT i.id, i.title, i.status, i.updated_at,
              COUNT(d.issue_id) AS tracked_count
       FROM hq.issues i
       LEFT JOIN hq.dependencies d ON d.depends_on_id = i.id
       WHERE i.issue_type = 'convoy'
         AND i.status NOT IN ('closed', 'deferred')
       GROUP BY i.id, i.title, i.status, i.updated_at
       ORDER BY i.updated_at DESC
       LIMIT 30`,
    )
    const entries = rows.map((r) => ({
      id: String(r.id ?? ''),
      title: String(r.title ?? ''),
      status: String(r.status ?? ''),
      tracked_count: Number(r.tracked_count ?? 0),
      updated_at: String(r.updated_at ?? ''),
    }))
    return c.html(convoysContent(entries))
  } catch (err) {
    console.error('[convoys route]', err)
    return c.html('<p class="empty">No active convoys</p>')
  }
})

export { convoys as convoysRoutes }
