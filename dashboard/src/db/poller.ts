import { pool } from './connection.js'
import { diffState } from '../lib/state-diff.js'
import { broadcast } from '../lib/sse.js'
import type { DashboardState, Issue } from '../lib/state-diff.js'

const POLL_INTERVAL_MS = 5000

let currentState: DashboardState | null = null

const ISSUE_COLS = `
  i.id,
  i.title,
  i.issue_type AS type,
  i.status,
  i.priority,
  i.assignee,
  i.updated_at,
  GROUP_CONCAT(l.label SEPARATOR ',') AS labels
`

function rowsToIssues(rows: any[]): Issue[] {
  return rows.map((r) => ({
    id: String(r.id ?? ''),
    title: String(r.title ?? ''),
    type: String(r.type ?? ''),
    status: String(r.status ?? ''),
    priority: Number(r.priority ?? 0),
    assignee: r.assignee != null ? String(r.assignee) : null,
    labels: r.labels != null ? String(r.labels) : null,
    updated_at: r.updated_at != null ? String(r.updated_at) : '',
  }))
}

async function fetchState(): Promise<DashboardState> {
  const [projectRows, beadRows, escalationRows, agentRows] = await Promise.all([
    // Projects: HQ issues labelled with any 'project:*' tag
    pool
      .query<any[]>(
        `SELECT ${ISSUE_COLS}
         FROM hq.issues i
         LEFT JOIN hq.labels l ON l.issue_id = i.id
         WHERE i.id IN (SELECT issue_id FROM hq.labels WHERE label LIKE 'project:%')
           AND i.status NOT IN ('closed','deferred')
         GROUP BY i.id
         ORDER BY i.updated_at DESC
         LIMIT 50`,
      )
      .then(([r]) => r),

    // Beads: active HQ issues for the victory rig
    pool
      .query<any[]>(
        `SELECT ${ISSUE_COLS}
         FROM hq.issues i
         LEFT JOIN hq.labels l ON l.issue_id = i.id
         WHERE i.id IN (SELECT issue_id FROM hq.labels WHERE label = 'rig:victory')
           AND i.status IN ('open','in_progress','blocked','hooked')
         GROUP BY i.id
         ORDER BY i.updated_at DESC
         LIMIT 30`,
      )
      .then(([r]) => r),

    // Escalations
    pool
      .query<any[]>(
        `SELECT ${ISSUE_COLS}
         FROM hq.issues i
         LEFT JOIN hq.labels l ON l.issue_id = i.id
         WHERE i.issue_type = 'escalation' OR i.title LIKE 'ESCALAT%'
         GROUP BY i.id
         ORDER BY i.updated_at DESC
         LIMIT 20`,
      )
      .then(([r]) => r),

    // Agents: patrol molecules + active polecats from victory rig
    pool
      .query<any[]>(
        `SELECT ${ISSUE_COLS.replace('hq.labels', 'victory.labels')}
         FROM victory.issues i
         LEFT JOIN victory.labels l ON l.issue_id = i.id
         WHERE i.issue_type IN ('molecule','polecat','agent')
           AND i.status NOT IN ('closed','deferred')
         GROUP BY i.id
         ORDER BY i.updated_at DESC
         LIMIT 20`,
      )
      .then(([r]) => r),
  ])

  return {
    projects: rowsToIssues(projectRows),
    beads: rowsToIssues(beadRows),
    escalations: rowsToIssues(escalationRows),
    agents: rowsToIssues(agentRows),
    timestamp: Date.now(),
  }
}

async function poll(): Promise<void> {
  try {
    const next = await fetchState()
    const changes = diffState(currentState, next)

    if (changes.length > 0) {
      broadcast('changes', changes)
    }

    for (const panel of ['projects', 'agents', 'beads', 'escalations'] as const) {
      broadcast(panel, next[panel])
    }

    currentState = next
  } catch (err) {
    console.error('[poller] poll error:', err)
  }
}

export function getCurrentState(): DashboardState | null {
  return currentState
}

export function startPoller(): void {
  poll() // immediate first poll
  setInterval(poll, POLL_INTERVAL_MS)
  console.log(`[poller] polling Dolt every ${POLL_INTERVAL_MS}ms`)
}
