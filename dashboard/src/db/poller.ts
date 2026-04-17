import { pool } from './connection.js'
import { diffState } from '../lib/state-diff.js'
import { broadcast, broadcastHtml } from '../lib/sse.js'
import type { DashboardState, Issue, BugEntry, ConvoyEntry } from '../lib/state-diff.js'
import { projectsContent } from '../views/project-card.js'
import { agentsContent } from '../views/agent-row.js'
import { beadTable } from '../views/bead-table.js'
import { escalationsContent } from '../views/escalation-item.js'
import { bugsContent } from '../views/bug-card.js'
import { convoysContent } from '../views/convoy-row.js'
import { polecatsContent } from '../views/polecat-row.js'
import { fetchPolecats } from '../routes/polecats.js'

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

function rowsToBugs(rows: any[]): BugEntry[] {
  return rows.map((r) => ({
    id: String(r.id ?? ''),
    code_area: String(r.code_area ?? ''),
    bug_title: String(r.bug_title ?? ''),
    occurrence_count: Number(r.occurrence_count ?? 1),
    status: String(r.status ?? ''),
  }))
}

function rowsToConvoys(rows: any[]): ConvoyEntry[] {
  return rows.map((r) => ({
    id: String(r.id ?? ''),
    title: String(r.title ?? ''),
    status: String(r.status ?? ''),
    tracked_count: Number(r.tracked_count ?? 0),
    updated_at: String(r.updated_at ?? ''),
  }))
}

async function fetchState(): Promise<DashboardState> {
  const [projectRows, beadRows, escalationRows, agentRows, bugRows, convoyRows, polecatEntries] = await Promise.all([
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

    // Bugs: active bug patterns from victory rig
    pool
      .query<any[]>(
        `SELECT id, code_area, bug_title, occurrence_count, status
         FROM victory.bug_memory
         WHERE status IN ('active', 'resolved')
         ORDER BY status ASC, occurrence_count DESC, created_at DESC
         LIMIT 20`,
      )
      .then(([r]) => r),

    // Convoys: active convoy issues from HQ
    pool
      .query<any[]>(
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
      .then(([r]) => r),

    // Polecats: read from GT runtime heartbeats
    fetchPolecats(),
  ])

  return {
    projects: rowsToIssues(projectRows),
    beads: rowsToIssues(beadRows),
    escalations: rowsToIssues(escalationRows),
    agents: rowsToIssues(agentRows),
    bugs: rowsToBugs(bugRows),
    convoys: rowsToConvoys(convoyRows),
    polecats: polecatEntries,
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

    // Broadcast HTML fragments for HTMX SSE swap
    broadcastHtml('projects', projectsContent(next.projects))
    broadcastHtml('agents', agentsContent(next.agents))
    broadcastHtml('beads', beadTable(next.beads))
    broadcastHtml('escalations', escalationsContent(next.escalations))
    broadcastHtml('bugs', bugsContent(next.bugs))
    broadcastHtml('convoys', convoysContent(next.convoys))
    broadcastHtml('polecats', polecatsContent(next.polecats))

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
