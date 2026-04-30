#!/usr/bin/env bash
# E2E smoke test: unified '+ Add Chart' flow — POST /v1/charts + POST /v1/charts/compute
#
# Covers the mi-onz P0 regression class: "Chart submit returns requested resource not found".
# Patch landed at api (ma-6g6) + iOS (mi-q19.2) + android (mi-q19.5). This test
# automates the user retest scenario so the regression class is gated by CI.
#
# 6 scenarios (all RGR — tests the fixed behaviour that would've been red pre-patch):
#   Scenario 1: POST /v1/charts/compute valid auth + birth data → 200 NatalChart, aspects[]
#   Scenario 2: POST /v1/charts kind=Person → 201 Chart resource with id + aspects[]
#   Scenario 3: POST /v1/charts kind=Event → 201, kind enum accepted
#   Scenario 4: POST /v1/charts kind=Moment → 201, free-form name preserved
#   Scenario 5: POST /v1/charts no auth → 401 {error:'Unauthorized'}
#   Scenario 6: POST /v1/charts/compute malformed body → 400 validation (NOT 502, NOT schema-shape)
#
# Usage (local — stack already running):
#   NO_COMPOSE=1 COMPOSE_FILE=/path/to/docker-compose.yml ./chart_smoke.sh
#
# Usage (local — start stack):
#   COMPOSE_FILE=/path/to/molly-api/docker-compose.yml ./chart_smoke.sh
#
# Usage (CI — stack started by workflow, COMPOSE_FILE already set):
#   NO_COMPOSE=1 COMPOSE_FILE=... ./chart_smoke.sh
#
# Exit codes: 0 = all checks passed, 1 = regression detected

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
API_BASE="${API_BASE:-http://localhost:3000}"
COMPOSE_FILE="${COMPOSE_FILE:-}"
NO_COMPOSE="${NO_COMPOSE:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗ FAIL:${NC} $*" >&2; exit 1; }
info() { echo -e "${YELLOW}→${NC} $*"; }

# Parse body+status from a curl -s -w "\n%{http_code}" response
http_status() { echo "$1" | tail -1; }
http_body()   { echo "$1" | sed '$d'; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " E2E smoke: unified '+ Add Chart' flow (vc-d5m)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Ensure stack is up ─────────────────────────────────────────────────
if [ -z "$NO_COMPOSE" ]; then
  if [ -z "$COMPOSE_FILE" ]; then
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

# ── Shared birth-data payloads ─────────────────────────────────────────────────
# New York, NY — 1990-06-15 14:30
COMPUTE_BODY='{
  "birthDate": "1990-06-15",
  "birthTime": "14:30",
  "latitude": 40.7128,
  "longitude": -74.0060,
  "timezone": "America/New_York"
}'

CHART_BASE='{
  "birthDate": "1990-06-15",
  "birthTime": "14:30",
  "birthLat": 40.7128,
  "birthLng": -74.0060,
  "birthTimezone": "America/New_York",
  "birthLocationText": "New York, NY"
}'

# ══════════════════════════════════════════════════════════════════════════════
# Scenario 1: POST /v1/charts/compute → 200 NatalChart with aspects[]
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Scenario 1: POST /v1/charts/compute → 200 NatalChart"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 3: POST /v1/charts/compute with valid auth + birth data"
SC1_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/v1/charts/compute" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$COMPUTE_BODY") || fail "Sc1: curl failed on POST /v1/charts/compute"

SC1_STATUS=$(http_status "$SC1_RESP")
SC1_BODY=$(http_body "$SC1_RESP")

[ "$SC1_STATUS" != "200" ] && fail "Sc1: Expected 200, got $SC1_STATUS. Body: $SC1_BODY"

SC1_SUN=$(echo "$SC1_BODY" | jq -r '.sunSign // empty')
SC1_MOON=$(echo "$SC1_BODY" | jq -r '.moonSign // empty')
SC1_RISING=$(echo "$SC1_BODY" | jq -r '.risingSign // empty')

[ -z "$SC1_SUN" ]    && fail "Sc1: NatalChart missing sunSign. Body: $SC1_BODY"
[ -z "$SC1_MOON" ]   && fail "Sc1: NatalChart missing moonSign. Body: $SC1_BODY"
[ -z "$SC1_RISING" ] && fail "Sc1: NatalChart missing risingSign. Body: $SC1_BODY"

echo "$SC1_BODY" | jq -e '.aspects | type == "array"' >/dev/null \
  || fail "Sc1: NatalChart.aspects is not an array. Body: $SC1_BODY"
echo "$SC1_BODY" | jq -e '.planets | type == "array"' >/dev/null \
  || fail "Sc1: NatalChart.planets is not an array. Body: $SC1_BODY"

SC1_ASPECT_COUNT=$(echo "$SC1_BODY" | jq '.aspects | length')
pass "Sc1: POST /v1/charts/compute → 200 NatalChart (sun=$SC1_SUN moon=$SC1_MOON rising=$SC1_RISING aspects=$SC1_ASPECT_COUNT)"

# ══════════════════════════════════════════════════════════════════════════════
# Scenario 2: POST /v1/charts kind=Person → 201 Chart resource
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Scenario 2: POST /v1/charts kind=Person → 201"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 4: POST /v1/charts kind=Person"
PERSON_BODY=$(echo "$CHART_BASE" | jq '. + {"name": "Smoke Test Person", "kind": "Person"}')
SC2_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/v1/charts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PERSON_BODY") || fail "Sc2: curl failed on POST /v1/charts"

SC2_STATUS=$(http_status "$SC2_RESP")
SC2_BODY=$(http_body "$SC2_RESP")

[ "$SC2_STATUS" != "201" ] && fail "Sc2: Expected 201, got $SC2_STATUS. Body: $SC2_BODY"

SC2_ID=$(echo "$SC2_BODY" | jq -r '.id // empty')
SC2_KIND=$(echo "$SC2_BODY" | jq -r '.kind // empty')
[ -z "$SC2_ID" ]            && fail "Sc2: Response missing id. Body: $SC2_BODY"
[ "$SC2_KIND" != "Person" ] && fail "Sc2: Expected kind=Person, got '$SC2_KIND'. Body: $SC2_BODY"
echo "$SC2_BODY" | jq -e '.aspects | type == "array"' >/dev/null \
  || fail "Sc2: Response missing aspects[]. Body: $SC2_BODY"

pass "Sc2: POST /v1/charts kind=Person → 201, id=$SC2_ID kind=$SC2_KIND aspects=$(echo "$SC2_BODY" | jq '.aspects | length')"

# ══════════════════════════════════════════════════════════════════════════════
# Scenario 3: POST /v1/charts kind=Event → 201, kind enum accepted
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Scenario 3: POST /v1/charts kind=Event → 201"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 5: POST /v1/charts kind=Event"
EVENT_BODY=$(echo "$CHART_BASE" | jq '. + {"name": "Company Launch", "kind": "Event"}')
SC3_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/v1/charts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$EVENT_BODY") || fail "Sc3: curl failed on POST /v1/charts"

SC3_STATUS=$(http_status "$SC3_RESP")
SC3_BODY=$(http_body "$SC3_RESP")

[ "$SC3_STATUS" != "201" ] && fail "Sc3: Expected 201, got $SC3_STATUS. Body: $SC3_BODY"

SC3_KIND=$(echo "$SC3_BODY" | jq -r '.kind // empty')
[ "$SC3_KIND" != "Event" ] && fail "Sc3: Expected kind=Event, got '$SC3_KIND'. Body: $SC3_BODY"
echo "$SC3_BODY" | jq -e '.aspects | type == "array"' >/dev/null \
  || fail "Sc3: Response missing aspects[]. Body: $SC3_BODY"

pass "Sc3: POST /v1/charts kind=Event → 201, kind=$SC3_KIND ✓"

# ══════════════════════════════════════════════════════════════════════════════
# Scenario 4: POST /v1/charts kind=Moment → 201, free-form name preserved
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Scenario 4: POST /v1/charts kind=Moment, name preserved"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 6: POST /v1/charts kind=Moment with free-form name"
MOMENT_NAME="The moment I decided to move to Tokyo"
MOMENT_BODY=$(echo "$CHART_BASE" | jq --arg name "$MOMENT_NAME" '. + {"name": $name, "kind": "Moment"}')
SC4_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/v1/charts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$MOMENT_BODY") || fail "Sc4: curl failed on POST /v1/charts"

SC4_STATUS=$(http_status "$SC4_RESP")
SC4_BODY=$(http_body "$SC4_RESP")

[ "$SC4_STATUS" != "201" ] && fail "Sc4: Expected 201, got $SC4_STATUS. Body: $SC4_BODY"

SC4_KIND=$(echo "$SC4_BODY" | jq -r '.kind // empty')
SC4_NAME=$(echo "$SC4_BODY" | jq -r '.name // empty')
[ "$SC4_KIND" != "Moment" ]       && fail "Sc4: Expected kind=Moment, got '$SC4_KIND'. Body: $SC4_BODY"
[ "$SC4_NAME" != "$MOMENT_NAME" ] && fail "Sc4: Name not preserved. Expected '$MOMENT_NAME', got '$SC4_NAME'. Body: $SC4_BODY"

pass "Sc4: POST /v1/charts kind=Moment → 201, kind=$SC4_KIND, name preserved ✓"

# ══════════════════════════════════════════════════════════════════════════════
# Scenario 5: POST /v1/charts no auth → 401 {error:'Unauthorized'}
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Scenario 5: POST /v1/charts no auth → 401 Unauthorized"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 7: POST /v1/charts with no Authorization header"
NO_AUTH_BODY=$(echo "$CHART_BASE" | jq '. + {"name": "No Auth Test", "kind": "Person"}')
SC5_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/v1/charts" \
  -H "Content-Type: application/json" \
  -d "$NO_AUTH_BODY") || fail "Sc5: curl failed on POST /v1/charts"

SC5_STATUS=$(http_status "$SC5_RESP")
SC5_BODY=$(http_body "$SC5_RESP")

[ "$SC5_STATUS" != "401" ] && fail "Sc5: Expected 401, got $SC5_STATUS. Body: $SC5_BODY"

SC5_ERROR=$(echo "$SC5_BODY" | jq -r '.error // empty')
[ "$SC5_ERROR" != "Unauthorized" ] \
  && fail "Sc5: Expected {error:'Unauthorized'}, got '$SC5_ERROR'. Body: $SC5_BODY"

pass "Sc5: POST /v1/charts (no auth) → 401 {error:'Unauthorized'} ✓"

# ══════════════════════════════════════════════════════════════════════════════
# Scenario 6: POST /v1/charts/compute malformed body → 4xx (NOT 502, NOT schema-shape)
# ══════════════════════════════════════════════════════════════════════════════
# Key regression guard: mi-onz was returning 502/resource-not-found for bad input.
# Must get a client-error (4xx) with an error envelope, never a 5xx.
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Scenario 6: POST /v1/charts/compute malformed → 4xx (not 502)"
echo "═══════════════════════════════════════════════════════════"
echo ""

info "Step 8: POST /v1/charts/compute with malformed body (missing required fields)"
SC6_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/v1/charts/compute" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"birthDate": "not-a-date"}') || fail "Sc6: curl failed on POST /v1/charts/compute"

SC6_STATUS=$(http_status "$SC6_RESP")
SC6_BODY=$(http_body "$SC6_RESP")

[ "$SC6_STATUS" = "502" ] \
  && fail "Sc6: Got 502 — malformed input crashed the astro service (schema-shape regression). Body: $SC6_BODY"
[ "$SC6_STATUS" -ge 500 ] \
  && fail "Sc6: Got 5xx ($SC6_STATUS) — server error on malformed input. Body: $SC6_BODY"
[ "$SC6_STATUS" -lt 400 ] \
  && fail "Sc6: Expected 4xx, got $SC6_STATUS — malformed input not rejected. Body: $SC6_BODY"

SC6_ERROR=$(echo "$SC6_BODY" | jq -r '.error // empty')
[ -z "$SC6_ERROR" ] && fail "Sc6: Response missing error field. Body: $SC6_BODY"

pass "Sc6: POST /v1/charts/compute (malformed) → $SC6_STATUS {error:'$SC6_ERROR'} — not 502, not schema-shape ✓"

# ── All checks passed ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Chart smoke test PASSED  ✓  (vc-d5m)${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
