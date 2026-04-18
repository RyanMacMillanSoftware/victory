# Molly System Architecture

> **Last updated:** 2026-04-18
> **Scope:** Full-system overview covering all four Molly services, their relationships, and primary data flows.

---

## What Molly Is

Molly is an AI-powered astrology companion app. Users share their birth data, and Molly uses that natal chart combined with current planetary transits to provide personalized astrological insights through a conversational interface. Molly is not a generic chatbot — she has a distinct personality (defined in a Character Bible) and builds a persistent memory of each user over time.

---

## Services

| Service | Language / Framework | Repo | Hosting | Port |
|---|---|---|---|---|
| **molly-api** | TypeScript / Node.js / Hono | `RyanMacMillanSoftware/molly-api` | Railway (auto-deploy on push to `main`) | 3000 |
| **molly-astro** | Python 3.11 / FastAPI / Kerykeion | `RyanMacMillanSoftware/molly-astro` | Railway (auto-deploy on push to `main`) | 8000 |
| **molly-ios** | Swift 6 / SwiftUI | `RyanMacMillanSoftware/molly-ios` | App Store (manual Archive + TestFlight) | — |
| **molly-android** | Kotlin 2.1 / Jetpack Compose | `RyanMacMillanSoftware/molly-android` | Play Store (manual `bundleRelease`) | — |

### molly-api — Backend Gateway

The central backend. Every client request flows through here. Responsibilities:

- **Authentication** — Apple Sign-In and Google Sign-In token verification, JWT issuance/refresh
- **Conversations** — create/list conversations; accept user messages and stream Molly's response via Server-Sent Events
- **Memory** — extract factual memories from each conversation turn; store and retrieve them across sessions
- **Natal chart management** — delegate calculation to molly-astro; cache results in PostgreSQL
- **User profiles** — birth data, display name, consent flags, onboarding state
- **Subscriptions** — receive and process RevenueCat webhooks; gate premium features by tier
- **Push notifications** — device token registration; send notifications via Firebase Admin SDK
- **Observability** — Prometheus metrics (`/metrics`), pino structured logging, OpenTelemetry traces

### molly-astro — Astrology Engine

A dedicated microservice for astrological calculation, called exclusively by molly-api. It wraps the Swiss Ephemeris via the Kerykeion library.

- **Natal chart** — compute sun/moon/rising, planet positions, house cusps, and aspects from birth data
- **Current transits** — live planetary positions and moon phase
- **Transit aspects** — aspects between current transiting planets and a user's natal chart
- **Metadata enrichment** — add interpretive metadata to chart data

molly-astro has no database. It is stateless — all inputs come in via HTTP and all outputs go out in the same response.

### molly-ios — iOS Client

Native iPhone app (SwiftUI, iOS 17+, Swift 6 strict concurrency).

- **Onboarding** — collect birth data and sign in with Apple
- **Chat** — send messages to molly-api; render Molly's streaming SSE response token by token
- **Paywall** — subscribe or restore purchases via RevenueCat SDK
- **Settings** — profile and birth data management
- Architecture: MVVM with `@Observable` view models, protocol-abstracted services

### molly-android — Android Client

Native Android app (Jetpack Compose, Material 3, min SDK 26).

- **Onboarding** — birth data entry and Google/Apple Sign-In
- **Chat** — streaming SSE via Ktor `SseClient`
- **Paywall** — RevenueCat in-app subscriptions
- **Push notifications** — Firebase Cloud Messaging
- Architecture: multi-module Gradle (`app`, `core:network`, `core:data`, `core:model`, `core:common`) with Hilt DI

---

## Service Topology

```
┌─────────────────────────────────────────────────────────────┐
│                       Mobile Clients                         │
│                  molly-ios  /  molly-android                 │
└─────────────┬───────────────────────────────────────────────┘
              │ HTTPS / SSE
              ▼
┌─────────────────────────────────────────────────────────────┐
│                        molly-api                             │
│  ┌──────────┐  ┌────────────┐  ┌──────────┐  ┌──────────┐  │
│  │  Routes   │  │  Services  │  │Character │  │ Middleware│  │
│  │  auth     │  │  claude    │  │  Bible   │  │  auth     │  │
│  │  convo    │  │  memory    │  │  identity│  │  crisis   │  │
│  │  users    │  │  astro     │  │  context │  │  rate-lmt │  │
│  │  devices  │  │  push      │  └──────────┘  └──────────┘  │
│  │  onboard  │  │  crisis    │                               │
│  │  subscr.  │  └────────────┘                               │
│  └──────────┘                                                │
└──────┬──────────┬────────────┬──────────────────────────────┘
       │          │            │
       │ HTTP     │ Bolt       │ gRPC
       ▼          ▼            ▼
 molly-astro   Neo4j        Qdrant
 (Python/      (memory      (vector
  FastAPI)      graph)       search)

 Also: PostgreSQL (Neon in prod) ◄── molly-api
       Anthropic Claude API     ◄── molly-api
       RevenueCat webhooks      ──► molly-api
       Firebase Admin SDK       ◄── molly-api (push)
       Apple / Google Sign-In   ◄── molly-api (auth verification)
```

---

## Data Stores

| Store | Technology | What lives here |
|---|---|---|
| **PostgreSQL** | pg (dev) / Neon serverless (prod) | Users, refresh tokens, conversations, messages (with token usage), natal charts, crisis events, device tokens |
| **Neo4j** | Graph database | Memory entity graph — named entities (people, relationships, themes) and the fact-edges that connect them, with confidence and decay metadata |
| **Qdrant** | Vector database | Semantic embeddings of memory facts; powers similarity search for surfacing relevant memories at prompt-assembly time |

---

## Primary Data Flows

### 1. User Onboarding

```
Client → POST /v1/onboarding/start
       ← 200 (session created)

Client → POST /v1/auth/apple  (or /google)
         { identity_token, birth_date, birth_place, ... }
       ← { access_token, refresh_token }

molly-api: verifies identity token with Apple/Google
           creates user row in PostgreSQL
           calls molly-astro POST /natal/chart with birth data
           stores NatalChart in PostgreSQL
```

### 2. Conversation and Streaming Chat

```
Client → POST /v1/conversations
       ← { conversation: { id, type } }

Client → POST /v1/conversations/:id/messages
         { content: "..." }
       ← SSE stream (event: "token", data: { token })
         ...
         SSE event: "done" (or stream close)

Inside molly-api (concurrent):
  1. Persist user message to PostgreSQL
  2. Fetch conversation history from PostgreSQL
  3. Prompt assembly (parallel fetches):
       a. Identity anchor (Character Bible — identity layer)
       b. Relationship context from Neo4j (relationship layer)
       c. Surfaced memories from Qdrant (semantic search)
       d. Current transits from molly-astro GET /transits/current
       e. Transit aspects from molly-astro POST /transits/aspects
  4. Crisis detection scan on user message (Claude structured call)
     → If high crisis: inject crisis addendum into prompt, log CrisisEvent
  5. Stream Claude response token-by-token → SSE to client
  6. Persist assistant message to PostgreSQL (with token usage + cost)
  7. Fire-and-forget background tasks:
       a. Memory extraction (Claude structured call → facts)
          → store facts to Neo4j (entities + edges) + Qdrant (embeddings)
       b. Conversation title generation (Claude structured call)
```

### 3. Memory Extraction and Storage

After each assistant response, molly-api fires an async background task:

```
extractMemoryFacts(userMessage, assistantMessage)
  → Claude structured call → ExtractionResult { facts[] }

For each fact:
  subject entity  → upsertEntity in Neo4j
  object entity   → upsertEntity in Neo4j
  fact edge       → createRelationship in Neo4j
                    (invalidates conflicting prior facts)
  embedding       → upsertPoint in Qdrant
                    (placeholder; TODO: replace with Voyage AI)
```

Memory facts are typed by category (`identity`, `episodic`, `emotional`, `relational`, `aspirational`) and decay class (`immune`, `slow`, `normal`).

### 4. Natal Chart Calculation

```
molly-api → POST /natal/chart
  { birth_date, birth_time, latitude, longitude, timezone, house_system }

molly-astro:
  Kerykeion (Swiss Ephemeris) computes:
    - Sun/Moon/Rising sign
    - Planet positions (sign, degree, house, retrograde)
    - House cusps (Placidus or Whole Sign)
    - Aspect patterns (conjunctions, trines, squares, etc.)
  Returns NatalChartResponse

molly-api:
  Normalizes snake_case → camelCase
  Persists to PostgreSQL `natal_charts` table
  Associates with user
```

### 5. System Prompt Assembly (Three-Layer Model)

Each conversation turn assembles a three-layer system prompt:

```
Layer 1 — Identity Anchor
  Source: Character Bible (versioned markdown file, cached in memory)
  Content: Molly's core identity, voice/tone, astrological framework,
           boundaries, crisis protocol, sample exchanges

Layer 2 — Relationship Context
  Source: Neo4j (entity graph traversal) + Qdrant (semantic memory search)
  Content: Known entities in the user's life, surfaced relevant memories,
           relationship evolution stage, conversation count

Layer 3 — Situational Context
  Source: molly-astro (live transits) + PostgreSQL (conversation history)
  Content: Current planetary positions, moon phase, transit aspects to natal
           chart, recent conversation history window
```

All three layers are fetched in parallel. Fetch failures degrade gracefully — missing layers fall back to empty sections.

### 6. Subscription Management

```
RevenueCat → POST /v1/subscriptions/webhook
  { event: { type, app_user_id, expiration_at_ms, ... } }

molly-api:
  Verifies webhook signature (REVENUECAT_WEBHOOK_SECRET)
  Handles event types: INITIAL_PURCHASE, RENEWAL, CANCELLATION,
                       EXPIRATION, BILLING_ISSUE, etc.
  Updates user.subscription_tier in PostgreSQL
  Activates/deactivates trial periods
```

### 7. Push Notifications

```
Client → POST /v1/devices
  { token, platform: "ios" | "android" }

molly-api:
  Stores device token in PostgreSQL

Server-side trigger (e.g., daily reminder):
  Queries device tokens for target users
  Firebase Admin SDK → FCM → device
```

---

## Authentication and Authorization

- **Apple Sign-In**: client sends identity token → molly-api verifies with Apple JWKS → issues JWT access token + refresh token
- **Google Sign-In**: same flow using Google token verification
- **JWT**: short-lived access tokens (signed with `JWT_SECRET`); refresh tokens stored in PostgreSQL with expiry
- **Auth middleware**: all `/v1/*` routes (except auth, health) require `Authorization: Bearer <token>`
- **Rate limiting**: `/v1/auth/*` endpoints have per-IP rate limiting to prevent brute-force

---

## Crisis Detection

Molly includes a safety layer that scans every user message before generating a response:

- Claude structured call detects crisis indicators (levels: `none`, `low`, `high`)
- **High crisis**: injects a crisis addendum into the system prompt with professional resource references; logs a `crisis_event` to PostgreSQL
- Rate limiting prevents crisis-response flooding for a single user
- Regional resource lists (`crisis-regions.ts`) localize helpline numbers by country

---

## Observability

| Signal | Technology | Endpoint / Destination |
|---|---|---|
| Structured logs | pino (JSON) | stdout → Railway log drain |
| Metrics | Prometheus / prom-client | `GET /metrics` → Prometheus scrape |
| Distributed traces | OpenTelemetry (OTLP HTTP) | → OTel Collector → Jaeger |

In production, a Railway-hosted OTel Collector aggregates traces from molly-api and forwards them to Jaeger for query and visualization.

---

## External Integrations

| Integration | Purpose | Direction |
|---|---|---|
| **Anthropic Claude** | AI backbone — streaming chat, memory extraction, title generation, crisis detection, transit aspects | molly-api → Anthropic API |
| **RevenueCat** | Subscription management and entitlement webhooks | RevenueCat → molly-api |
| **Firebase Admin SDK** | Push notification delivery via FCM | molly-api → Firebase |
| **Apple Sign-In** | Identity token verification during auth | molly-api → Apple JWKS |
| **Google Sign-In** | Identity token verification during auth | molly-api → Google OAuth |
| **Swiss Ephemeris** (via Kerykeion) | Astronomical calculation library | molly-astro (embedded) |

---

## Development Environment

To run the full stack locally:

```bash
# 1. Start backing infrastructure (Postgres, Neo4j, Qdrant, Jaeger)
cd ~/Code/molly-api && docker compose up -d

# 2. Start molly-api
cp .env.example .env   # fill in ANTHROPIC_API_KEY, JWT_SECRET, etc.
npm run db:migrate
npm run dev            # port 3000

# 3. Start molly-astro
cd ~/Code/molly-astro
cp .env.example .env
uv sync
uv run uvicorn src.main:app --host 0.0.0.0 --port 8000

# 4. Verify all services ready
curl http://localhost:3000/ready   # all four backing services should report ok
curl http://localhost:8000/ready
```

For Android emulator: use `10.0.2.2` instead of `localhost` for backend URLs.

---

## Key Design Decisions

**Why Neo4j for memory?** Molly's memory is relational — "user's sister" connects to "user's sister's wedding" connects to "user's feelings about family". A graph database traverses these relationships naturally and supports invalidation of contradicted facts.

**Why Qdrant for memory retrieval?** Semantic search over conversation facts lets Molly surface the most relevant prior knowledge for each new message, without needing to load the entire memory graph into the prompt.

**Why a separate molly-astro service?** The Swiss Ephemeris / Kerykeion library is Python-only. Isolating it as a microservice keeps molly-api purely Node.js and allows independent scaling and deployment.

**Why SSE instead of WebSockets for streaming?** SSE is simpler (unidirectional, HTTP/1.1 compatible, auto-reconnect), sufficient for token-by-token streaming, and natively supported by both SwiftUI and Compose.

**Why three-layer prompts?** Separating identity (stable), relationship (session-persistent), and situational context (per-turn) makes each layer independently cacheable, debuggable, and tunable without touching the others.
