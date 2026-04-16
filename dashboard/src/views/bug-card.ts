export interface BugEntry {
  id: string
  code_area: string
  bug_title: string
  occurrence_count: number
  status: string
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

export function bugItem(row: BugEntry): string {
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

export function bugsContent(rows: BugEntry[]): string {
  if (rows.length === 0) return '<p class="empty">No bug patterns recorded</p>'
  return `<div class="bug-list">${rows.map(bugItem).join('\n')}</div>`
}
