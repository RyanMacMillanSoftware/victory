import type { Issue } from '../lib/state-diff.js'

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function trunc(s: string, n: number): string {
  return s.length > n ? s.slice(0, n) + '\u2026' : s
}

function statusBadge(status: string): string {
  const cls =
    status === 'in_progress' ? 'badge-active'
    : status === 'hooked' ? 'badge-hooked'
    : status === 'blocked' ? 'badge-blocked'
    : 'badge-open'
  return `<span class="badge ${cls}">${status.replace('_', '\u00a0')}</span>`
}

export function beadRow(issue: Issue): string {
  const assignee = issue.assignee
    ? esc(issue.assignee.split('/').pop() ?? issue.assignee)
    : '\u2014'
  return `<tr class="bead-row" data-id="${esc(issue.id)}">
  <td class="bead-id">${esc(issue.id)}</td>
  <td class="bead-title">${esc(trunc(issue.title, 72))}</td>
  <td>${statusBadge(issue.status)}</td>
  <td class="bead-assignee">${assignee}</td>
</tr>`
}

export function beadTable(issues: Issue[]): string {
  if (issues.length === 0) return '<p class="empty">No active beads</p>'
  return `<table class="data-table">
  <thead><tr><th>ID</th><th>Title</th><th>Status</th><th>Assignee</th></tr></thead>
  <tbody>${issues.map(beadRow).join('\n')}</tbody>
</table>`
}
