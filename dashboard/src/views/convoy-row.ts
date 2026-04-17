import type { ConvoyEntry } from '../lib/state-diff.js'

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function statusBadge(status: string): string {
  const cls = status === 'open' ? 'badge-open' : 'badge-closed'
  return `<span class="badge ${cls}">${esc(status)}</span>`
}

export function convoyRow(entry: ConvoyEntry): string {
  return `<tr class="convoy-row" data-id="${esc(entry.id)}">
  <td class="convoy-id">${esc(entry.id)}</td>
  <td class="convoy-title">${esc(entry.title)}</td>
  <td>${statusBadge(entry.status)}</td>
  <td class="convoy-count">${entry.tracked_count}</td>
</tr>`
}

export function convoysContent(entries: ConvoyEntry[]): string {
  if (entries.length === 0) return '<p class="empty">No active convoys</p>'
  return `<table class="data-table">
  <thead><tr><th>ID</th><th>Description</th><th>Status</th><th>Issues</th></tr></thead>
  <tbody>${entries.map(convoyRow).join('\n')}</tbody>
</table>`
}
