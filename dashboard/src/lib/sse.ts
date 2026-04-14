export type SSEWriter = (event: string, data: string) => Promise<void>

// JSON clients (programmatic consumers via /api/events)
const clients = new Map<string, SSEWriter>()

export function addClient(id: string, writer: SSEWriter): void {
  clients.set(id, writer)
}

export function removeClient(id: string): void {
  clients.delete(id)
}

export function broadcast(event: string, data: unknown): void {
  const payload = JSON.stringify(data)
  for (const [id, writer] of clients) {
    writer(event, payload).catch(() => {
      clients.delete(id)
    })
  }
}

export function clientCount(): number {
  return clients.size
}

// HTML clients (HTMX SSE swap via /api/live)
const htmlClients = new Map<string, SSEWriter>()

export function addHtmlClient(id: string, writer: SSEWriter): void {
  htmlClients.set(id, writer)
}

export function removeHtmlClient(id: string): void {
  htmlClients.delete(id)
}

export function broadcastHtml(event: string, html: string): void {
  for (const [id, writer] of htmlClients) {
    writer(event, html).catch(() => {
      htmlClients.delete(id)
    })
  }
}

export function htmlClientCount(): number {
  return htmlClients.size
}
