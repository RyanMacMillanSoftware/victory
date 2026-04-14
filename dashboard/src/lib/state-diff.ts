export interface Issue {
  id: string
  title: string
  type: string
  status: string
  priority: number
  assignee: string | null
  labels: string | null
  updated_at: string
}

export interface DashboardState {
  projects: Issue[]
  agents: Issue[]
  beads: Issue[]
  escalations: Issue[]
  timestamp: number
}

export type PanelKey = keyof Omit<DashboardState, 'timestamp'>

export type ChangeEvent =
  | { op: 'added'; panel: PanelKey; item: Issue }
  | { op: 'removed'; panel: PanelKey; id: string }
  | { op: 'updated'; panel: PanelKey; item: Issue }

const PANELS: PanelKey[] = ['projects', 'agents', 'beads', 'escalations']

export function diffState(
  prev: DashboardState | null,
  next: DashboardState,
): ChangeEvent[] {
  if (!prev) return []

  const events: ChangeEvent[] = []

  for (const panel of PANELS) {
    const prevItems = prev[panel] as Issue[]
    const nextItems = next[panel] as Issue[]

    const prevById = new Map(prevItems.map((i) => [i.id, i]))
    const nextById = new Map(nextItems.map((i) => [i.id, i]))

    for (const [id, item] of nextById) {
      if (!prevById.has(id)) {
        events.push({ op: 'added', panel, item })
      } else {
        const old = prevById.get(id)!
        if (old.updated_at !== item.updated_at || old.status !== item.status) {
          events.push({ op: 'updated', panel, item })
        }
      }
    }

    for (const id of prevById.keys()) {
      if (!nextById.has(id)) {
        events.push({ op: 'removed', panel, id })
      }
    }
  }

  return events
}
