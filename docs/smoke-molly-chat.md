# smoke-molly-chat.sh — E2E Chat Pipeline Smoke Test

**Bead:** `vc-0wv`  
**Created:** 2026-04-29

Cross-service smoke test that exercises the full chat pipeline: auth → conversation → SSE stream → sky aspects in response → Qdrant memory embedding. Catches two classes of regression that shipped in production on 2026-04-29:

1. **molly-api→molly-astro field mismatch** (e.g., `degree` vs `absolute_degree`) — produces 422 → silent 502 → no transits.
2. **Qdrant ULID rejection** (`ma-bx8`) — memory facts extracted from chat are never persisted because Qdrant rejects ULID-format point IDs.

---

## Running locally

```bash
# 1. Start the full stack
cd ~/Code/molly-api
docker compose up -d --wait

# 2. Run the smoke test
cd ~/gt/victory
./scripts/smoke-molly-chat.sh
```

With a real Anthropic API key in your environment, all assertions run. With a placeholder key, Claude-dependent assertions are skipped and only structural checks run.

```
── Preflight: checking required tools
  PASS  curl available
  PASS  jq available

── Stack health
  PASS  molly-api /health → ok
  PASS  qdrant service → ok (via /ready)
  PASS  molly-astro service → ok (via /ready)
  PASS  ANTHROPIC_API_KEY looks like a real key — full pipeline test enabled

── Authentication: POST /v1/auth/dev-login
  PASS  dev-login returned accessToken
  PASS  natal chart present (sun: Capricorn)

── Conversation: POST /v1/conversations
  PASS  conversation created: 01J...

── Qdrant: baseline point count
  PASS  Qdrant memory_facts collection: 12 points (baseline)

── Chat: POST /v1/conversations/.../messages
  PASS  SSE stream opened (HTTP 200)

── Parse SSE stream
  PASS  SSE stream contains planet name
  PASS  SSE stream contains aspect type
  PASS  SSE stream contains temporal marker (currently/now/today)

── Memory extraction: waiting 8s for async pipeline

── Qdrant: embedding upsert verification
  FAIL  Qdrant point count did NOT increase (was 12, still 12). Known cause: ULID point IDs rejected by Qdrant — see ma-bx8.

Results: 9 passed, 1 failed, 0 skipped
SMOKE TEST FAILED
```

The single failure is the **expected red test** — it becomes green after `ma-bx8` lands.

---

## CI integration (molly-api)

Add to `.github/workflows/smoke.yml` in the molly-api repo:

```yaml
name: E2E Smoke — Chat Pipeline

on:
  push:
    branches: [main]
  pull_request:
    paths:
      - 'src/**'
      - 'docker-compose.yml'

jobs:
  smoke:
    runs-on: ubuntu-latest
    timeout-minutes: 10

    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: molly
          POSTGRES_PASSWORD: molly
          POSTGRES_DB: molly
        options: >-
          --health-cmd "pg_isready -U molly"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
        ports:
          - 5432:5432

      qdrant:
        image: qdrant/qdrant:latest
        env:
          QDRANT__SERVICE__API_KEY: molly_qdrant_dev
        ports:
          - 6333:6333

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Start molly-astro
        run: |
          docker compose up -d molly-astro
          timeout 60 bash -c 'until curl -sf http://localhost:8000/health; do sleep 2; done'

      - name: Install deps + migrate
        run: |
          npm ci
          npm run db:migrate
        env:
          DATABASE_URL: postgresql://molly:molly@localhost:5432/molly

      - name: Start molly-api
        run: npm start &
        env:
          DATABASE_URL: postgresql://molly:molly@localhost:5432/molly
          QDRANT_URL: http://localhost:6333
          QDRANT_API_KEY: molly_qdrant_dev
          ASTRO_SERVICE_URL: http://localhost:8000
          JWT_SECRET: ${{ secrets.JWT_SECRET }}
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}

      - name: Wait for molly-api
        run: timeout 30 bash -c 'until curl -sf http://localhost:3000/health; do sleep 2; done'

      - name: Run smoke test
        run: |
          # Download and run the smoke test from victory repo
          curl -sf https://raw.githubusercontent.com/RyanMacMillanSoftware/victory/main/scripts/smoke-molly-chat.sh | bash
        env:
          MOLLY_API_URL: http://localhost:3000
          QDRANT_URL: http://localhost:6333
          QDRANT_API_KEY: molly_qdrant_dev
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

---

## Vitest integration (molly-api alternative)

For integration into `npm run test:integration`, add `tests/integration/e2e/smoke-chat-pipeline.test.ts` to molly-api with the same assertions using the in-process Hono app and real Postgres/Qdrant containers (see `docker-compose.test.yml`). This avoids the need to run a separate HTTP server and is faster in CI.

Key assertions that mirror this script:

```typescript
// 1. Transit wire contract: fields must be camelCase
expect(aspect).toHaveProperty("transitingPlanet");  // not transiting_planet
expect(aspect).toHaveProperty("natalPoint");         // not natal_point

// 2. Qdrant count increases after assistant response
expect(qdrantCountAfter).toBeGreaterThan(qdrantCountBefore);

// 3. No error thrown from storeFacts() (Qdrant rejects ULID IDs until ma-bx8)
// This is the RED assertion — passes after ma-bx8 lands
```

---

## Failure modes

| Assertion | Failure cause | Fix bead |
|-----------|---------------|----------|
| SSE has planet + aspect + temporal | Claude returns error (astro 422, wrong field names) | `ma-rz63` (landed) |
| Qdrant count increases | ULID point IDs rejected by Qdrant | `ma-bx8` (in flight) |
| `transitingPlanet` (camelCase) | Response not normalized | `ma-rz63` (landed) |
| Transit endpoint returns 200 | molly-astro unreachable or 422 | `ma-rz63` (landed) |
