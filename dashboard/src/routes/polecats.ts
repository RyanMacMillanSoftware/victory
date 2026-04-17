import { Hono } from 'hono'
import { readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { pool } from '../db/connection.js'
import { polecatsContent } from '../views/polecat-row.js'
import type { PolecatEntry } from '../lib/state-diff.js'

const HEARTBEAT_DIR = join(homedir(), 'gt', '.runtime', 'heartbeats')
const STALE_MS = 3 * 60 * 1000

const RIG_NAMES: Record<string, string> = {
  vc: 'victory',
  ch: 'chris',
  ma: 'molly_api',
  md: 'molly_android',
  mi: 'molly_ios',
  ms: 'molly_astro',
  hq: 'hq',
}

export async function fetchPolecats(): Promise<PolecatEntry[]> {
  // Read heartbeat files
  let files: string[] = []
  try {
    files = await readdir(HEARTBEAT_DIR)
  } catch {
    return []
  }

  const now = Date.now()
  const heartbeats: Array<{ id: string; name: string; rig: string; state: string; last_seen: string }> = []

  for (const file of files) {
    if (!file.endsWith('.json')) continue
    const base = file.slice(0, -5) // strip .json
    const dashIdx = base.indexOf('-')
    if (dashIdx === -1) continue
    const rigPrefix = base.slice(0, dashIdx)
    const name = base.slice(dashIdx + 1)
    const rig = RIG_NAMES[rigPrefix] ?? rigPrefix

    try {
      const raw = await readFile(join(HEARTBEAT_DIR, file), 'utf8')
      const hb = JSON.parse(raw) as { timestamp: string; state: string }
      heartbeats.push({ id: base, name, rig, state: hb.state, last_seen: hb.timestamp })
    } catch {
      // skip unreadable files
    }
  }

  // Query Dolt for hooked beads per polecat assignee
  const hookedByAssignee = new Map<string, string>()
  try {
    const [rows] = await pool.query<any[]>(
      `SELECT id, assignee
       FROM victory.issues
       WHERE status = 'hooked'
         AND assignee LIKE 'victory/polecats/%'`,
    )
    for (const r of rows) {
      if (r.assignee) hookedByAssignee.set(String(r.assignee), String(r.id))
    }
  } catch {
    // best-effort — continue without bead IDs
  }

  return heartbeats.map((hb) => {
    const ts = new Date(hb.last_seen).getTime()
    const stale = now - ts > STALE_MS
    const status = stale ? 'stale' : hb.state
    const assignee = `victory/polecats/${hb.name}`
    return {
      id: hb.id,
      name: hb.name,
      rig: hb.rig,
      status,
      bead_id: hookedByAssignee.get(assignee) ?? null,
      last_seen: hb.last_seen,
    }
  }).sort((a, b) => a.id.localeCompare(b.id))
}

const polecats = new Hono()

polecats.get('/', async (c) => {
  try {
    const entries = await fetchPolecats()
    return c.html(polecatsContent(entries))
  } catch (err) {
    console.error('[polecats route]', err)
    return c.html('<p class="empty">No active polecats</p>')
  }
})

export { polecats as polecatsRoutes }
