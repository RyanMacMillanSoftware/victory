import type { Issue } from '../lib/state-diff.js'

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function parseSeverity(title: string): 'critical' | 'high' | 'medium' | 'low' {
  const m = title.match(/^\[(CRITICAL|HIGH|MEDIUM|LOW)\]/)
  if (!m) return 'low'
  return m[1].toLowerCase() as 'critical' | 'high' | 'medium' | 'low'
}

function stripSeverityPrefix(title: string): string {
  return title.replace(/^\[(CRITICAL|HIGH|MEDIUM|LOW)\]\s*/, '')
}

export function escalationItem(issue: Issue): string {
  const severity = parseSeverity(issue.title)
  const resolved = issue.status === 'closed'
  return `<div class="esc-item esc-${severity}${resolved ? ' esc-resolved' : ''}" data-id="${esc(issue.id)}">
  <div class="esc-meta">
    <span class="badge badge-sev-${severity}">${severity}</span>
    <span class="esc-id">${esc(issue.id)}</span>
    ${resolved ? '<span class="badge badge-closed">resolved</span>' : ''}
  </div>
  <p class="esc-title">${esc(stripSeverityPrefix(issue.title))}</p>
</div>`
}

export function escalationsContent(issues: Issue[]): string {
  if (issues.length === 0) return '<p class="empty">No active escalations</p>'
  return `<div class="esc-list">${issues.map(escalationItem).join('\n')}</div>`
}
