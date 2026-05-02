#!/usr/bin/env bash
# E2E smoke test: all 13 tool round-trips + sky aspects + Qdrant embedding pipeline
#
# Exercises all 13 molly tools across 11 prompts:
#   Phase 1:  get_planet_position / get_ephemeris   (historical date query)
#   Phase 2:  save_person_chart_to_memory, recall_person_chart_by_name,
#             forget_person, compute_synastry, get_compatibility_summary
#   Phase 3:  get_retrograde_calendar, get_aspect_calendar, get_lunar_calendar
#   Sky:      get_transits (sky aspects prompt, Qdrant embedding check)
#   Charts:   get_saved_charts, lookup_saved_chart_by_name
#
# Catches cross-service regressions spanning molly-api + molly-astro + Qdrant.
# Historical failures caught: api/astro path mismatch (2026-04-29), Qdrant ULID rejection,
# silent tool-calling regression (tick 21 — tools never invoked despite Phase 1 contract).
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

# ── Tool-use round-trip: historical ephemeris query (Phase 1 milestone lock) ───
# Added by vc-phc: assert tool_use happens for date-specific questions.
# Mars was in Aquarius on July 4th, 1776. Catches silent regressions like tick 21
# where tools were never invoked despite the Phase 1 contract being live.
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool-use round-trip: historical date ephemeris (Phase 1)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 9: POST /v1/conversations (new conversation for tool-use test)"
CONV2_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (tool-use) failed"

CONV2_ID=$(echo "$CONV2_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV2_ID" ] && fail "No conversation.id in response: $CONV2_RESP"
pass "Step 9: Created conversation (tool-use): $CONV2_ID"

info "Step 10: Sending historical date query — 'Where was Mars on July 4th 1776?'"
CALL_START_EPOCH=$(date +%s)
SSE2_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV2_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "Where was Mars on July 4th 1776?"}') \
  || fail "Mars 1776 message POST failed (curl exited non-zero)"
CALL_ELAPSED=$(( $(date +%s) - CALL_START_EPOCH + 5 ))

FULL_TEXT2=$(printf '%s\n' "$SSE2_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT2" ] && fail "SSE stream for Mars 1776 produced no token text. Full body: $(printf '%s\n' "$SSE2_BODY" | head -20)"
pass "Step 10: SSE stream received (${#FULL_TEXT2} chars)"

# ── Step 11: Assert at least 1 tool_use event emitted ─────────────────────────
info "Step 11: Asserting at least 1 tool_use event (SSE stream or API log)"

# Check A: any SSE data line containing "tool_use" JSON string (content block)
TOOL_USE_IN_SSE=$(printf '%s\n' "$SSE2_BODY" \
  | grep '^data:' \
  | grep -c '"tool_use"' 2>/dev/null || echo "0")

# Check B: 'tool invocation' log line from molly-api during the call window
TOOL_INV_IN_LOGS=0
MOLLY_API_CTR=$(docker ps --filter "name=molly-api" --format "{{.Names}}" 2>/dev/null | head -1)
if [ -n "$MOLLY_API_CTR" ]; then
  TOOL_INV_IN_LOGS=$(docker logs "$MOLLY_API_CTR" --since "${CALL_ELAPSED}s" 2>&1 \
    | grep -c "tool invocation" 2>/dev/null || echo "0")
elif [ -n "$COMPOSE_FILE" ]; then
  TOOL_INV_IN_LOGS=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${CALL_ELAPSED}s" 2>&1 \
    | grep -c "tool invocation" 2>/dev/null || echo "0")
else
  echo -e "${YELLOW}⚠${NC}  Cannot locate molly-api container for log check — relying on SSE check only"
fi

if [ "$TOOL_USE_IN_SSE" -gt 0 ]; then
  pass "Step 11: tool_use event in SSE stream ($TOOL_USE_IN_SSE occurrence(s))"
elif [ "$TOOL_INV_IN_LOGS" -gt 0 ]; then
  pass "Step 11: 'tool invocation' in API logs ($TOOL_INV_IN_LOGS line(s))"
else
  fail "Step 11: No tool_use event in SSE stream and no 'tool invocation' in API logs. Tool calling is NOT happening for historical date queries — Phase 1 regression detected."
fi

# ── Step 11b: Assert specific ephemeris tool (Phase 1 refinement) ─────────────
info "Step 11b: Asserting get_planet_position OR get_ephemeris specifically invoked"

EPH_IN_SSE=$(printf '%s\n' "$SSE2_BODY" \
  | grep '^data:' \
  | grep -cE '"get_planet_position"|"get_ephemeris"' 2>/dev/null || echo "0")

if [ "$EPH_IN_SSE" -gt 0 ]; then
  pass "Step 11b: get_planet_position/get_ephemeris invoked ($EPH_IN_SSE occurrence(s))"
else
  fail "Step 11b: Neither get_planet_position nor get_ephemeris in SSE for Mars 1776 date query — Phase 1 tool routing regression."
fi

# ── Step 12: Assert Aquarius in response ──────────────────────────────────────
info "Step 12: Asserting response contains 'Aquarius' (Mars sign, July 4th 1776)"
if ! echo "$FULL_TEXT2" | grep -qiE "Aquarius"; then
  fail "Step 12: Response does not contain 'Aquarius'. Mars was in Aquarius on July 4th 1776. Preview: ${FULL_TEXT2:0:400}"
fi
pass "Step 12: 'Aquarius' confirmed in response ✓"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: get_retrograde_calendar, get_aspect_calendar, get_lunar_calendar
# Phase 2: save_person_chart_to_memory, recall_person_chart_by_name
# NOTE: Step 15 (get_retrograde_calendar) expected red until ms-23h merges.
# ══════════════════════════════════════════════════════════════════════════════

# ── Step 13–15: get_retrograde_calendar ───────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: get_retrograde_calendar (Phase 3)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 13: POST /v1/conversations (retrograde test)"
CONV3_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (retrograde) failed"

CONV3_ID=$(echo "$CONV3_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV3_ID" ] && fail "No conversation.id in retrograde conversation response"
pass "Step 13: Created conversation (retrograde): $CONV3_ID"

info "Step 14: Sending retrograde query — 'When is the next Mercury retrograde?'"
RETRO_START=$(date +%s)
RETRO_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV3_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "When is the next Mercury retrograde?"}') \
  || fail "Mercury retrograde message POST failed"
RETRO_ELAPSED=$(( $(date +%s) - RETRO_START + 5 ))

FULL_TEXT3=$(printf '%s\n' "$RETRO_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT3" ] && fail "SSE stream for retrograde query produced no token text. Body: $(printf '%s\n' "$RETRO_BODY" | head -10)"
pass "Step 14: SSE stream received (${#FULL_TEXT3} chars)"

info "Step 15: Asserting get_retrograde_calendar invoked + response has dates"

RETRO_TOOL_IN_SSE=$(printf '%s\n' "$RETRO_BODY" \
  | grep '^data:' \
  | grep -c '"get_retrograde_calendar"' 2>/dev/null || echo "0")

if [ "$RETRO_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 15a: get_retrograde_calendar in SSE ($RETRO_TOOL_IN_SSE occurrence(s))"
else
  RETRO_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    RETRO_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${RETRO_ELAPSED}s" 2>&1 \
      | grep -c "get_retrograde_calendar" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    RETRO_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${RETRO_ELAPSED}s" 2>&1 \
      | grep -c "get_retrograde_calendar" 2>/dev/null || echo "0")
  fi
  if [ "$RETRO_TOOL_LOG" -gt 0 ]; then
    pass "Step 15a: get_retrograde_calendar in logs ($RETRO_TOOL_LOG line(s))"
  else
    fail "Step 15a: get_retrograde_calendar NOT invoked for 'When is the next Mercury retrograde?' — Phase 3 regression."
  fi
fi

if ! echo "$FULL_TEXT3" | grep -qiE '[0-9]{4}|January|February|March|April|May|June|July|August|September|October|November|December'; then
  fail "Step 15b: Response contains no date for retrograde query. Preview: ${FULL_TEXT3:0:300}"
fi
pass "Step 15b: Date reference present in retrograde response"

# ── Step 16–18: get_aspect_calendar ──────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: get_aspect_calendar (Phase 3)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 16: POST /v1/conversations (aspect test)"
CONV4_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (aspect) failed"

CONV4_ID=$(echo "$CONV4_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV4_ID" ] && fail "No conversation.id in aspect conversation response"
pass "Step 16: Created conversation (aspect): $CONV4_ID"

info "Step 17: Sending aspect query — 'When does Saturn next square my Sun?'"
ASPECT_START=$(date +%s)
ASPECT_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV4_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "When does Saturn next square my Sun?"}') \
  || fail "Saturn aspect message POST failed"
ASPECT_ELAPSED=$(( $(date +%s) - ASPECT_START + 5 ))

FULL_TEXT4=$(printf '%s\n' "$ASPECT_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT4" ] && fail "SSE stream for aspect query produced no token text. Body: $(printf '%s\n' "$ASPECT_BODY" | head -10)"
pass "Step 17: SSE stream received (${#FULL_TEXT4} chars)"

info "Step 18: Asserting get_aspect_calendar invoked + response has a date"

ASPECT_TOOL_IN_SSE=$(printf '%s\n' "$ASPECT_BODY" \
  | grep '^data:' \
  | grep -c '"get_aspect_calendar"' 2>/dev/null || echo "0")

if [ "$ASPECT_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 18a: get_aspect_calendar in SSE ($ASPECT_TOOL_IN_SSE occurrence(s))"
else
  ASPECT_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    ASPECT_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${ASPECT_ELAPSED}s" 2>&1 \
      | grep -c "get_aspect_calendar" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    ASPECT_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${ASPECT_ELAPSED}s" 2>&1 \
      | grep -c "get_aspect_calendar" 2>/dev/null || echo "0")
  fi
  if [ "$ASPECT_TOOL_LOG" -gt 0 ]; then
    pass "Step 18a: get_aspect_calendar in logs ($ASPECT_TOOL_LOG line(s))"
  else
    fail "Step 18a: get_aspect_calendar NOT invoked for 'When does Saturn next square my Sun?' — Phase 3 regression."
  fi
fi

if ! echo "$FULL_TEXT4" | grep -qiE '[0-9]{4}|January|February|March|April|May|June|July|August|September|October|November|December'; then
  fail "Step 18b: Response contains no date for aspect query. Preview: ${FULL_TEXT4:0:300}"
fi
pass "Step 18b: Date reference present in aspect response"

# ── Step 19–21: get_lunar_calendar ───────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: get_lunar_calendar (Phase 3)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 19: POST /v1/conversations (lunar test)"
CONV5_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (lunar) failed"

CONV5_ID=$(echo "$CONV5_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV5_ID" ] && fail "No conversation.id in lunar conversation response"
pass "Step 19: Created conversation (lunar): $CONV5_ID"

info "Step 20: Sending lunar query — 'When is the next full moon?'"
LUNAR_START=$(date +%s)
LUNAR_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV5_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "When is the next full moon?"}') \
  || fail "Full moon message POST failed"
LUNAR_ELAPSED=$(( $(date +%s) - LUNAR_START + 5 ))

FULL_TEXT5=$(printf '%s\n' "$LUNAR_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT5" ] && fail "SSE stream for lunar query produced no token text. Body: $(printf '%s\n' "$LUNAR_BODY" | head -10)"
pass "Step 20: SSE stream received (${#FULL_TEXT5} chars)"

info "Step 21: Asserting get_lunar_calendar invoked + response has a date"

LUNAR_TOOL_IN_SSE=$(printf '%s\n' "$LUNAR_BODY" \
  | grep '^data:' \
  | grep -c '"get_lunar_calendar"' 2>/dev/null || echo "0")

if [ "$LUNAR_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 21a: get_lunar_calendar in SSE ($LUNAR_TOOL_IN_SSE occurrence(s))"
else
  LUNAR_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    LUNAR_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${LUNAR_ELAPSED}s" 2>&1 \
      | grep -c "get_lunar_calendar" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    LUNAR_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${LUNAR_ELAPSED}s" 2>&1 \
      | grep -c "get_lunar_calendar" 2>/dev/null || echo "0")
  fi
  if [ "$LUNAR_TOOL_LOG" -gt 0 ]; then
    pass "Step 21a: get_lunar_calendar in logs ($LUNAR_TOOL_LOG line(s))"
  else
    fail "Step 21a: get_lunar_calendar NOT invoked for 'When is the next full moon?' — Phase 3 regression."
  fi
fi

if ! echo "$FULL_TEXT5" | grep -qiE '[0-9]{4}|January|February|March|April|May|June|July|August|September|October|November|December|full moon'; then
  fail "Step 21b: Response contains no date for lunar query. Preview: ${FULL_TEXT5:0:300}"
fi
pass "Step 21b: Date reference present in lunar response"

# ── Steps 22–25: save_person_chart_to_memory + recall_person_chart_by_name ────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: save + recall person chart (Phase 2)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 22: POST /v1/conversations (memory tools test)"
CONV6_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (memory tools) failed"

CONV6_ID=$(echo "$CONV6_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV6_ID" ] && fail "No conversation.id in memory tools conversation response"
pass "Step 22: Created conversation (memory tools): $CONV6_ID"

info "Step 23: Sending save-person query — 'Save Sarah, Scorpio Sun born Nov 3 1992'"
SAVE_START=$(date +%s)
SAVE_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV6_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "Save Sarah, Scorpio Sun born Nov 3 1992"}') \
  || fail "Save Sarah message POST failed"
SAVE_ELAPSED=$(( $(date +%s) - SAVE_START + 5 ))

FULL_TEXT6=$(printf '%s\n' "$SAVE_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT6" ] && fail "SSE stream for save-person query produced no token text. Body: $(printf '%s\n' "$SAVE_BODY" | head -10)"
pass "Step 23: SSE stream received (${#FULL_TEXT6} chars)"

info "Step 24: Asserting save_person_chart_to_memory invoked"

SAVE_TOOL_IN_SSE=$(printf '%s\n' "$SAVE_BODY" \
  | grep '^data:' \
  | grep -c '"save_person_chart_to_memory"' 2>/dev/null || echo "0")

if [ "$SAVE_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 24: save_person_chart_to_memory in SSE ($SAVE_TOOL_IN_SSE occurrence(s))"
else
  SAVE_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    SAVE_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${SAVE_ELAPSED}s" 2>&1 \
      | grep -c "save_person_chart_to_memory" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    SAVE_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${SAVE_ELAPSED}s" 2>&1 \
      | grep -c "save_person_chart_to_memory" 2>/dev/null || echo "0")
  fi
  if [ "$SAVE_TOOL_LOG" -gt 0 ]; then
    pass "Step 24: save_person_chart_to_memory in logs ($SAVE_TOOL_LOG line(s))"
  else
    fail "Step 24: save_person_chart_to_memory NOT invoked for 'Save Sarah, Scorpio Sun born Nov 3 1992' — Phase 2 regression."
  fi
fi

info "Step 25: Sending recall query — 'Remind me about Sarah' (same conversation)"
RECALL_START=$(date +%s)
RECALL_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV6_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "Remind me about Sarah"}') \
  || fail "Recall Sarah message POST failed"
RECALL_ELAPSED=$(( $(date +%s) - RECALL_START + 5 ))

FULL_TEXT7=$(printf '%s\n' "$RECALL_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT7" ] && fail "SSE stream for recall query produced no token text. Body: $(printf '%s\n' "$RECALL_BODY" | head -10)"
pass "Step 25a: SSE stream received (${#FULL_TEXT7} chars)"

RECALL_TOOL_IN_SSE=$(printf '%s\n' "$RECALL_BODY" \
  | grep '^data:' \
  | grep -c '"recall_person_chart_by_name"' 2>/dev/null || echo "0")

if [ "$RECALL_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 25b: recall_person_chart_by_name in SSE ($RECALL_TOOL_IN_SSE occurrence(s))"
else
  RECALL_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    RECALL_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${RECALL_ELAPSED}s" 2>&1 \
      | grep -c "recall_person_chart_by_name" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    RECALL_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${RECALL_ELAPSED}s" 2>&1 \
      | grep -c "recall_person_chart_by_name" 2>/dev/null || echo "0")
  fi
  if [ "$RECALL_TOOL_LOG" -gt 0 ]; then
    pass "Step 25b: recall_person_chart_by_name in logs ($RECALL_TOOL_LOG line(s))"
  else
    fail "Step 25b: recall_person_chart_by_name NOT invoked for 'Remind me about Sarah' — Phase 2 memory regression."
  fi
fi

if ! echo "$FULL_TEXT7" | grep -qiE 'Sarah|Scorpio|November'; then
  fail "Step 25c: Response contains no Sarah/Scorpio/November reference after recall. Preview: ${FULL_TEXT7:0:300}"
fi
pass "Step 25c: Sarah/Scorpio reference present in recall response"

# ── Steps 26–28: get_saved_charts ────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: get_saved_charts (saved-charts surface)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 26: POST /v1/conversations (get_saved_charts test)"
CONV7_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (get_saved_charts) failed"

CONV7_ID=$(echo "$CONV7_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV7_ID" ] && fail "No conversation.id in get_saved_charts conversation response"
pass "Step 26: Created conversation (get_saved_charts): $CONV7_ID"

info "Step 27: Sending query — 'Who do I have saved charts for?'"
CHARTS_START=$(date +%s)
CHARTS_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV7_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "Who do I have saved charts for? List all my saved people."}') \
  || fail "get_saved_charts message POST failed"
CHARTS_ELAPSED=$(( $(date +%s) - CHARTS_START + 5 ))

FULL_TEXT8=$(printf '%s\n' "$CHARTS_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT8" ] && fail "SSE stream for get_saved_charts query produced no token text. Body: $(printf '%s\n' "$CHARTS_BODY" | head -10)"
pass "Step 27: SSE stream received (${#FULL_TEXT8} chars)"

info "Step 28: Asserting get_saved_charts invoked"

CHARTS_TOOL_IN_SSE=$(printf '%s\n' "$CHARTS_BODY" \
  | grep '^data:' \
  | grep -c '"get_saved_charts"' 2>/dev/null || echo "0")

if [ "$CHARTS_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 28: get_saved_charts in SSE ($CHARTS_TOOL_IN_SSE occurrence(s))"
else
  CHARTS_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    CHARTS_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${CHARTS_ELAPSED}s" 2>&1 \
      | grep -c "get_saved_charts" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    CHARTS_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${CHARTS_ELAPSED}s" 2>&1 \
      | grep -c "get_saved_charts" 2>/dev/null || echo "0")
  fi
  if [ "$CHARTS_TOOL_LOG" -gt 0 ]; then
    pass "Step 28: get_saved_charts in logs ($CHARTS_TOOL_LOG line(s))"
  else
    fail "Step 28: get_saved_charts NOT invoked for 'Who do I have saved charts for?' — saved-charts surface regression."
  fi
fi

# ── Steps 29–31: lookup_saved_chart_by_name ───────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: lookup_saved_chart_by_name (saved-charts surface)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 29: POST /v1/conversations (lookup_saved_chart_by_name test)"
CONV8_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (lookup_saved_chart_by_name) failed"

CONV8_ID=$(echo "$CONV8_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV8_ID" ] && fail "No conversation.id in lookup_saved_chart_by_name conversation response"
pass "Step 29: Created conversation (lookup_saved_chart_by_name): $CONV8_ID"

info "Step 30: Sending query — 'Look up my saved chart for Sarah'"
LOOKUP_START=$(date +%s)
LOOKUP_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV8_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "Look up my saved chart for Sarah and tell me her details."}') \
  || fail "lookup_saved_chart_by_name message POST failed"
LOOKUP_ELAPSED=$(( $(date +%s) - LOOKUP_START + 5 ))

FULL_TEXT9=$(printf '%s\n' "$LOOKUP_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT9" ] && fail "SSE stream for lookup_saved_chart_by_name query produced no token text. Body: $(printf '%s\n' "$LOOKUP_BODY" | head -10)"
pass "Step 30: SSE stream received (${#FULL_TEXT9} chars)"

info "Step 31: Asserting lookup_saved_chart_by_name invoked + Sarah in response"

LOOKUP_TOOL_IN_SSE=$(printf '%s\n' "$LOOKUP_BODY" \
  | grep '^data:' \
  | grep -c '"lookup_saved_chart_by_name"' 2>/dev/null || echo "0")

if [ "$LOOKUP_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 31a: lookup_saved_chart_by_name in SSE ($LOOKUP_TOOL_IN_SSE occurrence(s))"
else
  LOOKUP_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    LOOKUP_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${LOOKUP_ELAPSED}s" 2>&1 \
      | grep -c "lookup_saved_chart_by_name" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    LOOKUP_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${LOOKUP_ELAPSED}s" 2>&1 \
      | grep -c "lookup_saved_chart_by_name" 2>/dev/null || echo "0")
  fi
  if [ "$LOOKUP_TOOL_LOG" -gt 0 ]; then
    pass "Step 31a: lookup_saved_chart_by_name in logs ($LOOKUP_TOOL_LOG line(s))"
  else
    fail "Step 31a: lookup_saved_chart_by_name NOT invoked for 'Look up my saved chart for Sarah' — saved-charts regression."
  fi
fi

if ! echo "$FULL_TEXT9" | grep -qiE 'Sarah|Scorpio|November|1992'; then
  fail "Step 31b: Response contains no Sarah/Scorpio/November/1992 reference. Preview: ${FULL_TEXT9:0:300}"
fi
pass "Step 31b: Sarah/Scorpio reference present in lookup response"

# ── Steps 32–34: get_compatibility_summary ────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: get_compatibility_summary (Phase 2)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 32: POST /v1/conversations (get_compatibility_summary test)"
CONV9_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (get_compatibility_summary) failed"

CONV9_ID=$(echo "$CONV9_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV9_ID" ] && fail "No conversation.id in get_compatibility_summary conversation response"
pass "Step 32: Created conversation (get_compatibility_summary): $CONV9_ID"

info "Step 33: Sending query — 'What is my astrological compatibility with Sarah?'"
COMPAT_START=$(date +%s)
COMPAT_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV9_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "What is my astrological compatibility with Sarah? Give me a compatibility summary."}') \
  || fail "get_compatibility_summary message POST failed"
COMPAT_ELAPSED=$(( $(date +%s) - COMPAT_START + 5 ))

FULL_TEXT10=$(printf '%s\n' "$COMPAT_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT10" ] && fail "SSE stream for get_compatibility_summary query produced no token text. Body: $(printf '%s\n' "$COMPAT_BODY" | head -10)"
pass "Step 33: SSE stream received (${#FULL_TEXT10} chars)"

info "Step 34: Asserting get_compatibility_summary invoked"

COMPAT_TOOL_IN_SSE=$(printf '%s\n' "$COMPAT_BODY" \
  | grep '^data:' \
  | grep -c '"get_compatibility_summary"' 2>/dev/null || echo "0")

if [ "$COMPAT_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 34: get_compatibility_summary in SSE ($COMPAT_TOOL_IN_SSE occurrence(s))"
else
  COMPAT_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    COMPAT_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${COMPAT_ELAPSED}s" 2>&1 \
      | grep -c "get_compatibility_summary" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    COMPAT_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${COMPAT_ELAPSED}s" 2>&1 \
      | grep -c "get_compatibility_summary" 2>/dev/null || echo "0")
  fi
  if [ "$COMPAT_TOOL_LOG" -gt 0 ]; then
    pass "Step 34: get_compatibility_summary in logs ($COMPAT_TOOL_LOG line(s))"
  else
    fail "Step 34: get_compatibility_summary NOT invoked for compatibility query with Sarah — Phase 2 regression."
  fi
fi

# ── Steps 35–37: compute_synastry ─────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: compute_synastry (Phase 2)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 35: POST /v1/conversations (compute_synastry test)"
CONV10_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (compute_synastry) failed"

CONV10_ID=$(echo "$CONV10_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV10_ID" ] && fail "No conversation.id in compute_synastry conversation response"
pass "Step 35: Created conversation (compute_synastry): $CONV10_ID"

info "Step 36: Sending synastry query with explicit natal degrees"
SYNASTRY_START=$(date +%s)
SYNASTRY_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV10_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "My natal planets are at these ecliptic longitudes: Sun 15\u00b0 Aries (absolute degree 15), Moon 22\u00b0 Cancer (absolute degree 112), Venus 10\u00b0 Taurus (absolute degree 40). Please compute the synastry chart between my natal positions and Sarah\u2019s saved chart."}') \
  || fail "compute_synastry message POST failed"
SYNASTRY_ELAPSED=$(( $(date +%s) - SYNASTRY_START + 5 ))

FULL_TEXT11=$(printf '%s\n' "$SYNASTRY_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT11" ] && fail "SSE stream for compute_synastry query produced no token text. Body: $(printf '%s\n' "$SYNASTRY_BODY" | head -10)"
pass "Step 36: SSE stream received (${#FULL_TEXT11} chars)"

info "Step 37: Asserting compute_synastry invoked"

SYNASTRY_TOOL_IN_SSE=$(printf '%s\n' "$SYNASTRY_BODY" \
  | grep '^data:' \
  | grep -c '"compute_synastry"' 2>/dev/null || echo "0")

if [ "$SYNASTRY_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 37: compute_synastry in SSE ($SYNASTRY_TOOL_IN_SSE occurrence(s))"
else
  SYNASTRY_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    SYNASTRY_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${SYNASTRY_ELAPSED}s" 2>&1 \
      | grep -c "compute_synastry" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    SYNASTRY_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${SYNASTRY_ELAPSED}s" 2>&1 \
      | grep -c "compute_synastry" 2>/dev/null || echo "0")
  fi
  if [ "$SYNASTRY_TOOL_LOG" -gt 0 ]; then
    pass "Step 37: compute_synastry in logs ($SYNASTRY_TOOL_LOG line(s))"
  else
    fail "Step 37: compute_synastry NOT invoked for explicit synastry request with natal degrees — Phase 2 regression."
  fi
fi

# ── Steps 38–40: forget_person ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Tool round-trip: forget_person (Phase 2)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 38: POST /v1/conversations (forget_person test)"
CONV11_RESP=$(curl -sf -X POST "$API_BASE/v1/conversations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json") || fail "Create conversation (forget_person) failed"

CONV11_ID=$(echo "$CONV11_RESP" | jq -r '.conversation.id // empty')
[ -z "$CONV11_ID" ] && fail "No conversation.id in forget_person conversation response"
pass "Step 38: Created conversation (forget_person): $CONV11_ID"

info "Step 39: Sending query — 'Please forget Sarah from your memory'"
FORGET_START=$(date +%s)
FORGET_BODY=$(curl -sf -N \
  -X POST "$API_BASE/v1/conversations/$CONV11_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"content": "Please forget Sarah — delete her chart from your memory."}') \
  || fail "forget_person message POST failed"
FORGET_ELAPSED=$(( $(date +%s) - FORGET_START + 5 ))

FULL_TEXT12=$(printf '%s\n' "$FORGET_BODY" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '.token? // empty' 2>/dev/null \
  | tr -d '\n')

[ -z "$FULL_TEXT12" ] && fail "SSE stream for forget_person query produced no token text. Body: $(printf '%s\n' "$FORGET_BODY" | head -10)"
pass "Step 39: SSE stream received (${#FULL_TEXT12} chars)"

info "Step 40: Asserting forget_person invoked + confirmation in response"

FORGET_TOOL_IN_SSE=$(printf '%s\n' "$FORGET_BODY" \
  | grep '^data:' \
  | grep -c '"forget_person"' 2>/dev/null || echo "0")

if [ "$FORGET_TOOL_IN_SSE" -gt 0 ]; then
  pass "Step 40a: forget_person in SSE ($FORGET_TOOL_IN_SSE occurrence(s))"
else
  FORGET_TOOL_LOG=0
  if [ -n "$MOLLY_API_CTR" ]; then
    FORGET_TOOL_LOG=$(docker logs "$MOLLY_API_CTR" --since "${FORGET_ELAPSED}s" 2>&1 \
      | grep -c "forget_person" 2>/dev/null || echo "0")
  elif [ -n "$COMPOSE_FILE" ]; then
    FORGET_TOOL_LOG=$(docker compose -f "$COMPOSE_FILE" logs molly-api --since "${FORGET_ELAPSED}s" 2>&1 \
      | grep -c "forget_person" 2>/dev/null || echo "0")
  fi
  if [ "$FORGET_TOOL_LOG" -gt 0 ]; then
    pass "Step 40a: forget_person in logs ($FORGET_TOOL_LOG line(s))"
  else
    fail "Step 40a: forget_person NOT invoked for 'Please forget Sarah' — Phase 2 regression."
  fi
fi

if ! echo "$FULL_TEXT12" | grep -qiE 'Sarah|forgot|removed|deleted|forget|no longer'; then
  fail "Step 40b: Response contains no forget/delete confirmation for Sarah. Preview: ${FULL_TEXT12:0:300}"
fi
pass "Step 40b: Forget confirmation present in response"

# ── All checks passed ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  E2E smoke test PASSED  ✓${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
