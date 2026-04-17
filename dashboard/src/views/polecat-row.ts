import type { PolecatEntry } from '../lib/state-diff.js'

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function statusBadge(status: string): string {
  const cls =
    status === 'working' ? 'badge-active'
    : status === 'idle' ? 'badge-open'
    : 'badge-blocked'
  return `<span class="badge ${cls}">${esc(status)}</span>`
}

export function polecatRow(entry: PolecatEntry): string {
  const beadCell = entry.bead_id
    ? `<td class="polecat-bead">${esc(entry.bead_id)}</td>`
    : `<td class="polecat-bead">—</td>`
  return `<tr class="polecat-row" data-id="${esc(entry.id)}">
  <td class="polecat-name">${esc(entry.name)}</td>
  <td class="polecat-rig">${esc(entry.rig)}</td>
  <td>${statusBadge(entry.status)}</td>
  ${beadCell}
</tr>`
}

export function polecatsContent(entries: PolecatEntry[]): string {
  if (entries.length === 0) return '<p class="empty">No active polecats</p>'
  return `<table class="data-table">
  <thead><tr><th>Name</th><th>Rig</th><th>Status</th><th>Bead</th></tr></thead>
  <tbody>${entries.map(polecatRow).join('\n')}</tbody>
</table>`
}
