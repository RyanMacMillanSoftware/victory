import type { Issue } from '../lib/state-diff.js'

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function statusBadge(status: string): string {
  const cls =
    status === 'in_progress' ? 'badge-active'
    : status === 'hooked' ? 'badge-hooked'
    : status === 'blocked' ? 'badge-blocked'
    : 'badge-open'
  return `<span class="badge ${cls}">${status.replace('_', '\u00a0')}</span>`
}

export function agentRow(issue: Issue): string {
  return `<tr class="agent-row" data-id="${esc(issue.id)}">
  <td class="agent-id">${esc(issue.id)}</td>
  <td class="agent-title">${esc(issue.title)}</td>
  <td>${statusBadge(issue.status)}</td>
</tr>`
}

export function agentsContent(issues: Issue[]): string {
  if (issues.length === 0) return '<p class="empty">No active agents</p>'
  return `<table class="data-table">
  <thead><tr><th>ID</th><th>Name</th><th>Status</th></tr></thead>
  <tbody>${issues.map(agentRow).join('\n')}</tbody>
</table>`
}
