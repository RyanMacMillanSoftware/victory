export type SSEWriter = (event: string, data: string) => Promise<void>

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
