import { Hono } from 'hono'
import { pool } from '../db/connection.js'

const bugs = new Hono()

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function bugItem(row: {
  id: string
  code_area: string
  bug_title: string
  occurrence_count: number
  status: string
}): string {
  const resolved = row.status === 'resolved'
  return `<div class="bug-item${resolved ? ' bug-resolved' : ''}" data-id="${esc(row.id)}">
  <div class="bug-meta">
    <span class="badge badge-code-area">${esc(row.code_area || 'general')}</span>
    ${resolved ? '<span class="badge badge-closed">resolved</span>' : ''}
    ${row.occurrence_count > 1 ? `<span class="badge badge-count">×${row.occurrence_count}</span>` : ''}
  </div>
  <p class="bug-title">${esc(row.bug_title)}</p>
</div>`
}

bugs.get('/', async (c) => {
  try {
    const [rows] = await pool.query<any[]>(
      `SELECT id, code_area, bug_title, occurrence_count, status
       FROM victory.bug_memory
       WHERE status IN ('active', 'resolved')
       ORDER BY status ASC, occurrence_count DESC, created_at DESC
       LIMIT 20`,
    )
    if (rows.length === 0) {
      return c.html('<p class="empty">No bug patterns recorded</p>')
    }
    return c.html(
      `<div class="bug-list">${rows.map(bugItem).join('\n')}</div>`,
    )
  } catch (err) {
    console.error('[bugs route]', err)
    return c.html('<p class="empty error">Unable to load bug patterns</p>')
  }
})

export { bugs as bugsRoutes }
