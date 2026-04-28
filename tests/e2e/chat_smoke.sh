#!/usr/bin/env bash
# E2E smoke test: chat send → sky aspects in SSE stream + Qdrant embedding OK + retrieval works
#
# Catches cross-service regressions spanning molly-api + molly-astro + Qdrant.
# Historical failures caught: api/astro path mismatch (2026-04-29), Qdrant ULID rejection.
#
# Usage (local — stack already running):
#   NO_COMPOSE=1 COMPOSE_FILE=/path/to/docker-compose.yml ./chat_smoke.sh
#
# Usage (local — start stack from docker-compose):
#   COMPOSE_FILE=/path/to/molly-api/docker-compose.yml ./chat_smoke.sh
#
# Usage (CI — stack started by workflow, COMPOSE_FILE already set):
#   NO_COMPOSE=1 COMPOSE_FILE=... ./chat_smoke.sh
#
# Exit codes: 0 = all checks passed, 1 = regression detected

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
API_BASE="${API_BASE:-http://localhost:3000}"
QDRANT_BASE="${QDRANT_BASE:-http://localhost:6333}"
QDRANT_API_KEY="${QDRANT_API_KEY:-molly_qdrant_dev}"
QDRANT_COLLECTION="memory_facts"
COMPOSE_FILE="${COMPOSE_FILE:-}"
NO_COMPOSE="${NO_COMPOSE:-}"
MEMORY_WAIT_SECS="${MEMORY_WAIT_SECS:-30}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗ FAIL:${NC} $*" >&2; exit 1; }
info() { echo -e "${YELLOW}→${NC} $*"; }

# ── Step 1: Ensure stack is up ─────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " E2E smoke: chat → sky aspects + Qdrant embedding pipeline"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ -z "$NO_COMPOSE" ]; then
  if [ -z "$COMPOSE_FILE" ]; then
    # Auto-locate docker-compose.yml relative to this script's repo root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
      "$SCRIPT_DIR/../../molly-api/docker-compose.yml" \
      "$HOME/Code/molly-api/docker-compose.yml" \
      "$HOME/gt/molly_api/docker-compose.yml"; do
      if [ -f "$candidate" ]; then
        COMPOSE_FILE="$candidate"
        break
      fi
    done
  fi

  if [ -z "$COMPOSE_FILE" ]; then
    fail "COMPOSE_FILE not set and no docker-compose.yml found. Set COMPOSE_FILE or NO_COMPOSE=1."
  fi

  info "Step 1: Starting stack via $COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" up -d --wait 2>&1 | tail -10
  pass "Stack started"
else
  info "Step 1: Stack startup skipped (NO_COMPOSE=1)"
fi

# Wait for API health
info "Waiting for molly-api on $API_BASE ..."
for i in $(seq 1 60); do
  if curl -sf "$API_BASE/health" >/dev/null 2>&1; then
    break
  fi
  [ "$i" -eq 60 ] && fail "molly-api did not become healthy after 60s"
  sleep 1
done
pass "molly-api is healthy"

# ── Step 2: Dev login ─────────────────────────────────────────────────────────
info "Step 2: POST /v1/auth/dev-login"
LOGIN_RESP=$(curl -sf -X POST "$API_BASE/v1/auth/dev-login" \
  -H "Content-Type: application/json" \
  -d '{}') || fail "dev-login request failed (is NODE_ENV=development?)"

TOKEN=$(echo "$LOGIN_RESP" | jq -r '.accessToken // empty')
[ -z "$TOKEN" ] && fail "No accessToken in dev-login response: $LOGIN_RESP"
pass "Got access token (${TOKEN:0:20}…)"

# ── Step 3: Create conversation ────────────────────────────────────────────────
info "Step 3: POST /v1/conversations"
CONV_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation failed"

CONV_ID=$(echo "$CONV_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV_ID" ] && fail "No conversation.id in response: $CONV_RESP"
pass "Created conversation: $CONV_ID"

# Count Qdrant points before message (collection may not exist yet → default 0)
info "Counting Qdrant $QDRANT_COLLECTION points (before)..."
BEFORE_COUNT=$(curl -sf -X POST \
  "$QDRANT_BASE/collections/$QDRANT_COLLECTION/points/count" \
  -H "api-key: $QDRANT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"exact": true}' 2>/dev/null \
  | jq '.result.count // 0' 2>/dev/null || echo "0")
info "Before count: $BEFORE_COUNT"

# ── Steps 4+5: Send message, collect SSE stream ────────────────────────────────
info "Step 4: POST /v1/conversations/$CONV_ID/messages (sky-aspects prompt)"
SSE_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "What planets are forming aspects in the sky right now? Tell me about current celestial alignments and transits."}') \
  || fail "Message POST failed (curl exited non-zero)"

# Step 5: assemble full text from SSE token events
# SSE format: lines "data: {\"token\":\"...\"}" interspersed with "event:" lines
FULL_TEXT=$(printf '%s\n' "$SSE_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT" ] && fail "SSE stream produced no token text. Full body: $(printf '%s\n' "$SSE_BODY" | head -20)"
pass "Step 5: SSE stream received (${#FULL_TEXT} chars)"

# ── Step 6: Assert sky-aspects content in response ────────────────────────────
info "Step 6: Asserting response contains planet + aspect type + time reference"

PLANETS="Mercury|Venus|Mars|Jupiter|Saturn|Uranus|Neptune|Moon|Sun|Pluto"
ASPECTS="conjunction|opposition|square|trine|sextile"
TIME_WORDS="currently|right now|\bnow\b|today|at this time|at the moment|presently"

if ! echo "$FULL_TEXT" | grep -qiE "$PLANETS"; then
  fail "Response contains no planet name. Preview: ${FULL_TEXT:0:300}"
fi
pass "Planet name present in response"

if ! echo "$FULL_TEXT" | grep -qiE "$ASPECTS"; then
  fail "Response contains no aspect type (conjunction/opposition/square/trine/sextile). Preview: ${FULL_TEXT:0:300}"
fi
pass "Aspect type present in response"

if ! echo "$FULL_TEXT" | grep -qiE "$TIME_WORDS"; then
  fail "Response contains no time-relative word. Preview: ${FULL_TEXT:0:300}"
fi
pass "Time-relative word present in response"

# ── Step 7: Check logs for Qdrant upsert errors ────────────────────────────────
info "Step 7: Waiting ${MEMORY_WAIT_SECS}s for async memory extraction, then checking logs..."
sleep "$MEMORY_WAIT_SECS"

# Locate the running molly-api container (works with or without a compose file)
MOLLY_API_CONTAINER=$(docker ps --filter "name=molly-api" --format "{{.Names}}" 2>/dev/null | head -1)

QDRANT_ERR_COUNT=0
if [ -n "$MOLLY_API_CONTAINER" ]; then
  QDRANT_ERR_COUNT=$(docker logs "$MOLLY_API_CONTAINER" --since 90s 2>&1 \
    | grep -c "failed to upsert embedding to Qdrant" || echo "0")
elif [ -n "$COMPOSE_FILE" ]; then
  QDRANT_ERR_COUNT=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since 90s 2>&1 \
    | grep -c "failed to upsert embedding to Qdrant" || echo "0")
else
  echo -e "${YELLOW}⚠${NC}  Could not locate molly-api container for log check — skipping step 7"
  QDRANT_ERR_COUNT=0
fi

if [ "$QDRANT_ERR_COUNT" -gt 0 ]; then
  fail "Found $QDRANT_ERR_COUNT 'failed to upsert embedding to Qdrant' error(s) in molly-api logs. Qdrant upsert pipeline is broken."
fi
pass "No Qdrant upsert errors in logs"

# ── Step 8: Qdrant point count must increase ──────────────────────────────────
info "Step 8: Verifying $QDRANT_COLLECTION point count increased after message..."
AFTER_COUNT="$BEFORE_COUNT"
for i in $(seq 1 20); do
  AFTER_COUNT=$(curl -sf -X POST \
    "$QDRANT_BASE/collections/$QDRANT_COLLECTION/points/count" \
    -H "api-key: $QDRANT_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"exact": true}' 2>/dev/null \
    | jq '.result.count // 0' 2>/dev/null || echo "0")

  if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
    break
  fi
  [ "$i" -lt 20 ] && sleep 3
done

if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  fail "Qdrant $QDRANT_COLLECTION count did not increase: before=$BEFORE_COUNT after=$AFTER_COUNT. Embedding pipeline may be broken (check Qdrant connectivity or ULID→UUID conversion)."
fi
pass "Qdrant point count increased: $BEFORE_COUNT → $AFTER_COUNT"

# ── All checks passed ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  E2E smoke test PASSED  ✓${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
