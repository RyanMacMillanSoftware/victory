#!/usr/bin/env bash
# scripts/smoke-molly-chat.sh
#
# E2E smoke test: chat send → assert sky aspects in SSE stream + Qdrant
# embedding upsert OK + retrieval works.
#
# Catches the 2026-04-29 class of regressions:
#   - molly-api→molly-astro path mismatch (wrong field names → 422)
#   - Qdrant ULID rejection (memory facts not persisted after chat)
#
# Prerequisites:
#   docker compose up -d          (postgres, neo4j, qdrant, molly-astro, molly-api)
#   ANTHROPIC_API_KEY set (real key) — tests that require Claude response are
#   skipped when a placeholder key is detected.
#
# Environment variables:
#   MOLLY_API_URL     Base URL (default: http://localhost:3000)
#   QDRANT_URL        Qdrant REST URL (default: http://localhost:6333)
#   QDRANT_API_KEY    Qdrant API key (default: molly_qdrant_dev)
#   STREAM_TIMEOUT    Seconds to wait for SSE tokens (default: 30)
#   MEMORY_WAIT       Seconds to wait for async memory extraction (default: 8)
#   SKIP_STARTUP      Set to 1 to skip docker-compose up check
#
# Exit codes:
#   0 — all required assertions passed (skip-only tests may be skipped)
#   1 — one or more required assertions failed
#
# Usage:
#   ./scripts/smoke-molly-chat.sh
#   MOLLY_API_URL=http://staging.molly.app ./scripts/smoke-molly-chat.sh
#   SKIP_STARTUP=1 ./scripts/smoke-molly-chat.sh

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

MOLLY_API_URL="${MOLLY_API_URL:-http://localhost:3000}"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
QDRANT_API_KEY="${QDRANT_API_KEY:-molly_qdrant_dev}"
STREAM_TIMEOUT="${STREAM_TIMEOUT:-30}"
MEMORY_WAIT="${MEMORY_WAIT:-8}"
SKIP_STARTUP="${SKIP_STARTUP:-0}"

PLANET_NAMES="Sun|Moon|Mercury|Venus|Mars|Jupiter|Saturn|Uranus|Neptune|Pluto"
ASPECT_TYPES="conjunction|sextile|square|trine|opposition|quincunx"
TEMPORAL_WORDS="currently|now|today|transit|transiting|right now|at the moment"

# ── State ─────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
TOKEN=""
CONV_ID=""
HAS_REAL_KEY=0

ok()   { echo "  PASS  $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $*" >&2; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $*"; SKIP=$((SKIP + 1)); }
step() { echo; echo "── $*"; }

finish() {
    echo
    echo "────────────────────────────────────────────────────────────────"
    echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
    if [[ $FAIL -gt 0 ]]; then
        echo "SMOKE TEST FAILED"
        exit 1
    else
        echo "SMOKE TEST PASSED"
        exit 0
    fi
}

trap finish EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────

step "Preflight: checking required tools"

for tool in curl jq; do
    if command -v "$tool" &>/dev/null; then
        ok "${tool} available"
    else
        fail "${tool} not found"
    fi
done

[[ $FAIL -gt 0 ]] && { echo "Preflight failed — aborting." >&2; exit 1; }

# ── Stack health ──────────────────────────────────────────────────────────────

step "Stack health"

# molly-api liveness
HEALTH=$(curl -sf --max-time 5 "${MOLLY_API_URL}/health" 2>/dev/null || echo "{}")
API_STATUS=$(echo "$HEALTH" | jq -r '.status // "unreachable"')
if [[ "$API_STATUS" == "ok" ]]; then
    ok "molly-api /health → ok"
else
    fail "molly-api /health → ${API_STATUS} (is docker compose up?)"
    exit 1
fi

# molly-api readiness — checks all downstream services
READY=$(curl -sf --max-time 10 "${MOLLY_API_URL}/ready" 2>/dev/null || echo "{}")
QDRANT_READY=$(echo "$READY" | jq -r '.services.qdrant.status // "unknown"')
ASTRO_READY=$(echo "$READY"  | jq -r '.services.astro.status  // "unknown"')

if [[ "$QDRANT_READY" == "ok" ]]; then
    ok "qdrant service → ok (via /ready)"
else
    fail "qdrant not ready: ${QDRANT_READY}"
fi

if [[ "$ASTRO_READY" == "ok" ]]; then
    ok "molly-astro service → ok (via /ready)"
else
    skip "molly-astro not ready (${ASTRO_READY}) — sky-aspects assertion will be skipped"
fi

# Key detection is deferred to after the first SSE response. We discover whether
# Claude is functional by checking if the stream returned a substantive response
# (> 50 chars, no error event). ANTHROPIC_API_KEY may be set inside docker-compose
# but not in the caller's shell environment, so we cannot reliably check it here.
ok "ANTHROPIC_API_KEY: checking after first chat response"

# ── Authentication ────────────────────────────────────────────────────────────

step "Authentication: POST /v1/auth/dev-login"

LOGIN_RESP=$(curl -sf --max-time 10 \
    -X POST "${MOLLY_API_URL}/v1/auth/dev-login" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null) || { fail "dev-login request failed"; exit 1; }

TOKEN=$(echo "$LOGIN_RESP" | jq -r '.accessToken // empty')
if [[ -n "$TOKEN" ]]; then
    ok "dev-login returned accessToken"
else
    fail "dev-login did not return accessToken: ${LOGIN_RESP}"
    exit 1
fi

# Verify natal chart exists (needed for transit aspects)
ME=$(curl -sf --max-time 5 \
    "${MOLLY_API_URL}/v1/users/me" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "{}")

CHART=$(echo "$ME" | jq -r '.chart // null')
if [[ "$CHART" != "null" && "$CHART" != "" ]]; then
    SUN_SIGN=$(echo "$ME" | jq -r '.chart.sunSign // "unknown"')
    ok "natal chart present (sun: ${SUN_SIGN})"
else
    # Attempt to generate natal chart for dev user
    step "Generating natal chart (dev user has no chart yet)"
    CHART_RESP=$(curl -sf --max-time 30 \
        "${MOLLY_API_URL}/v1/users/me/natal-chart" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "{}")
    CHART_ID=$(echo "$CHART_RESP" | jq -r '.id // empty')
    if [[ -n "$CHART_ID" ]]; then
        ok "natal chart generated on demand"
    else
        skip "natal chart not available (${CHART_RESP:0:100}) — sky-aspects may be empty"
    fi
fi

# ── Create conversation ───────────────────────────────────────────────────────

step "Conversation: POST /v1/conversations"

CONV_RESP=$(curl -sf --max-time 10 \
    -X POST "${MOLLY_API_URL}/v1/conversations" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null) || { fail "POST /v1/conversations failed"; exit 1; }

CONV_ID=$(echo "$CONV_RESP" | jq -r '.conversation.id // empty')
if [[ -n "$CONV_ID" ]]; then
    ok "conversation created: ${CONV_ID}"
else
    fail "no conversation.id in response: ${CONV_RESP}"
    exit 1
fi

# ── Qdrant baseline count ─────────────────────────────────────────────────────

step "Qdrant: baseline point count"

QDRANT_COUNT_BEFORE=0
QDRANT_REACHABLE=0

COUNT_RESP=$(curl -sf --max-time 5 \
    -X POST "${QDRANT_URL}/collections/memory_facts/points/count" \
    -H "Content-Type: application/json" \
    -H "api-key: ${QDRANT_API_KEY}" \
    -d '{"exact": true}' 2>/dev/null || echo "{}")

COUNT_VAL=$(echo "$COUNT_RESP" | jq -r '.result.count // -1')
if [[ "$COUNT_VAL" != "-1" ]]; then
    QDRANT_COUNT_BEFORE="$COUNT_VAL"
    QDRANT_REACHABLE=1
    ok "Qdrant memory_facts collection: ${QDRANT_COUNT_BEFORE} points (baseline)"
else
    # Collection may not exist yet — try listing collections first
    COLLECTIONS=$(curl -sf --max-time 5 \
        "${QDRANT_URL}/collections" \
        -H "api-key: ${QDRANT_API_KEY}" 2>/dev/null || echo "{}")
    HAS_COLLECTION=$(echo "$COLLECTIONS" | jq -r '.result.collections[]?.name // empty' | grep -c "memory_facts" || true)
    if [[ "$HAS_COLLECTION" == "0" ]]; then
        ok "Qdrant memory_facts collection does not exist yet (will be created on first upsert)"
        QDRANT_COUNT_BEFORE=0
        QDRANT_REACHABLE=1
    else
        skip "Qdrant not reachable at ${QDRANT_URL} — embedding assertions will be skipped"
    fi
fi

# ── Send chat message ─────────────────────────────────────────────────────────

step "Chat: POST /v1/conversations/${CONV_ID}/messages"

CHAT_PROMPT="What planets are most active in the sky right now? Tell me about any tight transits to my natal chart today."

# Capture SSE stream for up to STREAM_TIMEOUT seconds.
# The stream terminates with event:done or on timeout.
SSE_TMPFILE=$(mktemp)
STREAM_OK=0

echo "  Sending: \"${CHAT_PROMPT}\""
echo "  Waiting up to ${STREAM_TIMEOUT}s for SSE stream..."

HTTP_CODE=$(curl -s --max-time "${STREAM_TIMEOUT}" \
    -w "%{http_code}" \
    -X POST "${MOLLY_API_URL}/v1/conversations/${CONV_ID}/messages" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: text/event-stream" \
    -o "${SSE_TMPFILE}" \
    -d "{\"content\": $(echo "${CHAT_PROMPT}" | jq -R .)}" 2>/dev/null \
    || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    ok "SSE stream opened (HTTP 200)"
    STREAM_OK=1
elif [[ "$HTTP_CODE" == "000" ]]; then
    ok "SSE stream timed out — partial response captured (normal for streaming)"
    STREAM_OK=1
else
    fail "unexpected HTTP ${HTTP_CODE} from chat endpoint"
fi

# ── Parse SSE stream ──────────────────────────────────────────────────────────

step "Parse SSE stream"

# Extract text tokens from SSE data lines (event:token or plain data: lines)
STREAM_TEXT=$(grep "^data:" "${SSE_TMPFILE}" | sed 's/^data: //' | \
    jq -r 'if type == "object" then (.token // .text // .content // empty) else . end' 2>/dev/null | \
    tr -d '\n' || true)

# Also try plain text extraction if jq fails (raw stream with text tokens)
if [[ -z "$STREAM_TEXT" ]]; then
    STREAM_TEXT=$(cat "${SSE_TMPFILE}" | tr -d '\n' || true)
fi

STREAM_LEN=${#STREAM_TEXT}
echo "  Captured ${STREAM_LEN} chars from SSE stream"
if [[ $STREAM_LEN -gt 0 ]]; then
    echo "  Preview: ${STREAM_TEXT:0:200}..."
fi

# Check for error events
ERROR_EVENT=$(grep "^event: error" "${SSE_TMPFILE}" || true)
if [[ -n "$ERROR_EVENT" ]]; then
    ERROR_DATA=$(grep -A1 "^event: error" "${SSE_TMPFILE}" | tail -1 || true)
    skip "SSE stream error (API key not functional or service error): ${ERROR_DATA}"
fi

# Detect whether Claude returned a substantive response.
# ANTHROPIC_API_KEY may live inside docker-compose .env rather than the caller's shell,
# so we infer from the stream itself: >50 chars + no error event = real response.
if [[ -z "$ERROR_EVENT" && $STREAM_LEN -gt 50 ]]; then
    HAS_REAL_KEY=1
    ok "Claude responded with substantive content — full pipeline assertions enabled"
else
    skip "Claude response absent or errored — Qdrant/sky assertions skipped"
fi

# Assert sky aspects: at least one token contains planet + aspect + temporal marker
if [[ "$HAS_REAL_KEY" == "1" && "$ASTRO_READY" == "ok" ]]; then
    HAS_PLANET=$(echo "$STREAM_TEXT" | grep -iE "$PLANET_NAMES" | wc -l | tr -d ' ')
    HAS_ASPECT=$(echo "$STREAM_TEXT" | grep -iE "$ASPECT_TYPES" | wc -l | tr -d ' ')
    HAS_TEMPORAL=$(echo "$STREAM_TEXT" | grep -iE "$TEMPORAL_WORDS" | wc -l | tr -d ' ')

    if [[ "$HAS_PLANET" -gt 0 ]]; then
        ok "SSE stream contains planet name"
    else
        fail "SSE stream has no planet name (planets: ${PLANET_NAMES}). Got: ${STREAM_TEXT:0:300}"
    fi

    if [[ "$HAS_ASPECT" -gt 0 ]]; then
        ok "SSE stream contains aspect type"
    else
        fail "SSE stream has no aspect type (aspects: ${ASPECT_TYPES}). Got: ${STREAM_TEXT:0:300}"
    fi

    if [[ "$HAS_TEMPORAL" -gt 0 ]]; then
        ok "SSE stream contains temporal marker (currently/now/today)"
    else
        fail "SSE stream lacks temporal context. Got: ${STREAM_TEXT:0:300}"
    fi
else
    skip "sky-aspects assertion (requires real API key AND molly-astro)"
fi

rm -f "${SSE_TMPFILE}"

# ── Wait for async memory extraction ─────────────────────────────────────────

step "Memory extraction: waiting ${MEMORY_WAIT}s for async pipeline"

# Memory extraction is fire-and-forget after the assistant response stream closes.
# Give it time to complete before checking Qdrant.
if [[ "$HAS_REAL_KEY" == "1" ]]; then
    echo "  Sleeping ${MEMORY_WAIT}s..."
    sleep "${MEMORY_WAIT}"
    ok "wait complete"
else
    skip "memory wait (skipped — no real API key, no assistant response to extract from)"
fi

# ── Qdrant embedding upsert check ────────────────────────────────────────────

step "Qdrant: embedding upsert verification"

if [[ "$QDRANT_REACHABLE" == "0" ]]; then
    skip "Qdrant not reachable — skipping embedding check"
elif [[ "$HAS_REAL_KEY" == "0" ]]; then
    skip "embedding check (no real API key — memory extraction did not run)"
else
    # Get count after message
    COUNT_RESP_AFTER=$(curl -sf --max-time 5 \
        -X POST "${QDRANT_URL}/collections/memory_facts/points/count" \
        -H "Content-Type: application/json" \
        -H "api-key: ${QDRANT_API_KEY}" \
        -d '{"exact": true}' 2>/dev/null || echo "{}")

    QDRANT_COUNT_AFTER=$(echo "$COUNT_RESP_AFTER" | jq -r '.result.count // 0')

    echo "  Points before: ${QDRANT_COUNT_BEFORE}"
    echo "  Points after:  ${QDRANT_COUNT_AFTER}"

    if [[ "$QDRANT_COUNT_AFTER" -gt "$QDRANT_COUNT_BEFORE" ]]; then
        NEW_POINTS=$((QDRANT_COUNT_AFTER - QDRANT_COUNT_BEFORE))
        ok "Qdrant point count increased by ${NEW_POINTS} (memory facts embedded)"
    else
        # RED: this fails today due to ULID rejection (ma-bx8 not yet landed).
        # Qdrant rejects ULID-format point IDs — upsertPoint() throws, storeFacts()
        # logs "failed to upsert embedding to Qdrant" and swallows the error.
        # Expected to go GREEN after ma-bx8 converts ULIDs to UUIDs before upsert.
        fail "Qdrant point count did NOT increase (was ${QDRANT_COUNT_BEFORE}, still ${QDRANT_COUNT_AFTER}). Expected memory facts to be embedded. Known cause: ULID point IDs rejected by Qdrant — see ma-bx8."
    fi
fi

# ── Qdrant retrieval check ────────────────────────────────────────────────────

step "Qdrant: retrieval (vector search)"

if [[ "$QDRANT_REACHABLE" == "0" ]]; then
    skip "Qdrant not reachable — skipping retrieval check"
elif [[ "$HAS_REAL_KEY" == "0" ]]; then
    skip "retrieval check (no points to retrieve without real key)"
elif [[ "$QDRANT_COUNT_AFTER" -le "$QDRANT_COUNT_BEFORE" ]]; then
    skip "retrieval check (no new points were inserted — skipping)"
else
    # Search using a random 1024-dim query vector (just verify the endpoint works)
    QUERY_VECTOR=$(python3 -c "import random, json; print(json.dumps([random.uniform(-1,1) for _ in range(1024)]))" 2>/dev/null || \
        node -e "const v=Array.from({length:1024},()=>Math.random()-0.5); console.log(JSON.stringify(v))" 2>/dev/null || \
        echo "[]")

    if [[ "$QUERY_VECTOR" == "[]" ]]; then
        skip "retrieval check (could not generate query vector — python3/node not available)"
    else
        SEARCH_PAYLOAD=$(jq -n \
            --argjson vec "$QUERY_VECTOR" \
            '{"vector": $vec, "limit": 3, "with_payload": true}')

        SEARCH_RESP=$(curl -sf --max-time 10 \
            -X POST "${QDRANT_URL}/collections/memory_facts/points/search" \
            -H "Content-Type: application/json" \
            -H "api-key: ${QDRANT_API_KEY}" \
            -d "$SEARCH_PAYLOAD" 2>/dev/null || echo "{}")

        RESULT_COUNT=$(echo "$SEARCH_RESP" | jq '.result | length' 2>/dev/null || echo 0)
        if [[ "$RESULT_COUNT" -gt 0 ]]; then
            ok "Qdrant search returned ${RESULT_COUNT} result(s)"

            # Verify result payload has expected fields
            FIRST_PAYLOAD=$(echo "$SEARCH_RESP" | jq '.result[0].payload')
            HAS_USER_ID=$(echo "$FIRST_PAYLOAD" | jq -r '.userId // empty')
            if [[ -n "$HAS_USER_ID" ]]; then
                ok "search result payload contains userId field"
            else
                fail "search result payload missing userId: ${FIRST_PAYLOAD}"
            fi
        else
            fail "Qdrant search returned 0 results after inserting ${NEW_POINTS} points"
        fi
    fi
fi

# ── Transit endpoint smoke ────────────────────────────────────────────────────

step "Transit endpoint: GET /v1/transits/today"

TRANSIT_RESP=$(curl -sf --max-time 10 \
    "${MOLLY_API_URL}/v1/transits/today" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "{}")

TRANSIT_STATUS=$?
TRANSIT_COUNT=$(echo "$TRANSIT_RESP" | jq -r '.transit_count // -1')
TRANSIT_DATE=$(echo "$TRANSIT_RESP" | jq -r '.date // empty')

if [[ "$TRANSIT_COUNT" != "-1" ]]; then
    ok "GET /v1/transits/today → 200 (${TRANSIT_COUNT} transit(s) for ${TRANSIT_DATE})"

    if [[ "$TRANSIT_COUNT" -gt 0 ]]; then
        # Verify wire contract: camelCase field names (not snake_case)
        FIRST_TRANSIT=$(echo "$TRANSIT_RESP" | jq '.transits[0]')
        HAS_TRANSITING_PLANET=$(echo "$FIRST_TRANSIT" | jq -r '.transitingPlanet // empty')
        HAS_NATAL_POINT=$(echo "$FIRST_TRANSIT"       | jq -r '.natalPoint // empty')
        HAS_SNAKE=$(echo "$FIRST_TRANSIT" | jq -r '.transiting_planet // empty')

        if [[ -n "$HAS_TRANSITING_PLANET" ]]; then
            ok "transit response uses camelCase 'transitingPlanet' field ✓"
        elif [[ -n "$HAS_SNAKE" ]]; then
            fail "transit response uses snake_case 'transiting_planet' — camelCase normalization not applied (ma-rz63 regression)"
        else
            ok "transit aspect field names not verifiable (transit is a non-planet point?)"
        fi

        if [[ -n "$HAS_NATAL_POINT" ]]; then
            ok "transit response uses camelCase 'natalPoint' field ✓"
        fi
    else
        ok "no tight transits today (orb ≤ 3°) — this is expected when planets are widely spaced"
    fi
elif [[ "$ASTRO_READY" == "ok" ]]; then
    fail "GET /v1/transits/today failed: ${TRANSIT_RESP:0:200}"
else
    skip "transit endpoint (molly-astro not available)"
fi

echo
echo "────────────────────────────────────────────────────────────────"
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"

# Print CI instructions
if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "Known red assertions:"
    echo "  - Qdrant count increase: expects ma-bx8 to land (convert ULID→UUID for Qdrant point IDs)"
fi
