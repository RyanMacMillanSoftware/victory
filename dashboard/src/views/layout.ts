export function layout(title: string, body: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title} — Victory</title>
  <link rel="stylesheet" href="/public/styles.css">
  <script src="https://unpkg.com/htmx.org@2.0.4" integrity="sha384-HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+" crossorigin="anonymous"></script>
  <script src="https://unpkg.com/htmx-ext-sse@2.2.2/sse.js"></script>
</head>
<body>
  <header class="site-header">
    <div class="header-inner">
      <a class="brand" href="/">Victory</a>
      <nav>
        <a href="/">Dashboard</a>
      </nav>
      <span class="live-dot" title="Live updates active"></span>
    </div>
  </header>
  <main class="main-content">
    ${body}
  </main>
</body>
</html>`
}
