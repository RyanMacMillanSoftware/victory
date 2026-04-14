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

export function projectCard(issue: Issue): string {
  const assignee = issue.assignee
    ? `<span class="card-assignee">${esc(issue.assignee.split('/').pop() ?? issue.assignee)}</span>`
    : ''
  return `<div class="project-card" data-id="${esc(issue.id)}">
  <div class="card-meta">
    <span class="card-id">${esc(issue.id)}</span>
    ${statusBadge(issue.status)}
    ${assignee}
  </div>
  <p class="card-title">${esc(issue.title)}</p>
</div>`
}

export function projectsContent(issues: Issue[]): string {
  if (issues.length === 0) return '<p class="empty">No active projects</p>'
  return `<div class="project-list">${issues.map(projectCard).join('\n')}</div>`
}
