#!/usr/bin/env bash
# scripts/synthetic-monitor.sh
#
# Synthetic monitor: hits deployed api.molly.app endpoints and reports health.
# Designed to run as Railway cron OR GitHub Actions schedule every 5 min.
#
# Checks (in order):
#   1. GET /health          → HTTP 200
#   2. GET /ready           → HTTP 200
#   3. GET /v1/sky/today    → HTTP 200 (unauthenticated)
#   4. Chat round-trip      → dev-login + create conversation + send message → SSE data:
#      (skipped when NODE_ENV=production to avoid live PII)
#
# Output:
#   - Human-readable log to stdout
#   - Prometheus textfile format to stdout (appended at end) and to PROM_FILE if set
#
# Paging:
#   - Tracks consecutive failure count in STATE_FILE
#   - Sends a Sentry error event when count reaches FAIL_THRESHOLD
#   - Requires SENTRY_DSN env var; silently skips if unset
#
# Environment variables:
#   MOLLY_API_URL     Base URL (default: https://api.molly.app)
#   NODE_ENV          Skip chat round-trip when set to "production"
#   SENTRY_DSN        Sentry DSN for error reporting (optional)
#   FAIL_THRESHOLD    Consecutive failures before paging (default: 3)
#   STATE_FILE        Consecutive failure counter file (default: /tmp/synthetic-monitor-state)
#   PROM_FILE         Write Prometheus metrics to this file too (optional)
#   CURL_TIMEOUT      Per-request timeout in seconds (default: 10)
#   CHAT_TIMEOUT      Chat SSE timeout in seconds (default: 30)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

MOLLY_API_URL="${MOLLY_API_URL:-https://api.molly.app}"
NODE_ENV="${NODE_ENV:-}"
SENTRY_DSN="${SENTRY_DSN:-}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
STATE_FILE="${STATE_FILE:-/tmp/synthetic-monitor-state}"
PROM_FILE="${PROM_FILE:-}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
CHAT_TIMEOUT="${CHAT_TIMEOUT:-30}"

# ── State (parallel indexed arrays — bash 3.2 compatible) ────────────────────

CHECKS=()     # check names, in order
STATUSES=()   # parallel: 1=ok, 0=fail, -=skipped
LATENCIES=()  # parallel: milliseconds

OVERALL_OK=1

# ── Utilities ─────────────────────────────────────────────────────────────────

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Millisecond timestamp; falls back to python3 on macOS (BSD date lacks %N)
now_ms() {
  local out
  out=$(date +%s%3N 2>/dev/null || true)
  if printf '%s' "$out" | grep -qE '^[0-9]{13}$'; then
    printf '%s' "$out"
  else
    python3 -c "import time; print(int(time.time()*1000))"
  fi
}

log()  { echo "[$(ts)] $*"; }
pass() { log "  PASS  $*"; }
info() { log "  ....  $*"; }

record_check() {
  local name="$1" ok="$2" latency_ms="$3"
  CHECKS+=("$name")
  STATUSES+=("$ok")
  LATENCIES+=("$latency_ms")
  if [[ "$ok" == "1" ]]; then
    pass "${name} (${latency_ms}ms)"
  elif [[ "$ok" == "-" ]]; then
    log "  SKIP  ${name}"
  else
    log "  FAIL  ${name} (${latency_ms}ms)" >&2
    OVERALL_OK=0
  fi
}

# Run a simple HTTP check; expects HTTP 200, uses -s (not -f) to capture real code
http_check() {
  local name="$1" url="$2"
  shift 2
  local extra_args=()
  [[ $# -gt 0 ]] && extra_args=("$@")

  local t0 t1 latency_ms http_code
  t0=$(now_ms)
  # -s (silent) not -sf: -f overwrites captured code with "000" on error via ||
  http_code=$(curl -s --max-time "$CURL_TIMEOUT" \
    -o /dev/null -w "%{http_code}" \
    "${extra_args[@]+"${extra_args[@]}"}" "$url" 2>/dev/null) || http_code="000"
  t1=$(now_ms)
  latency_ms=$((t1 - t0))

  if [[ "$http_code" == "200" ]]; then
    record_check "$name" 1 "$latency_ms"
  else
    log "  FAIL  ${name}: HTTP ${http_code}" >&2
    record_check "$name" 0 "$latency_ms"
  fi
}

# ── Sentry ────────────────────────────────────────────────────────────────────

send_sentry_event() {
  local message="$1"
  [[ -z "$SENTRY_DSN" ]] && return 0

  local key host project timestamp event_id
  key="$(printf '%s' "$SENTRY_DSN" | sed 's|https://||' | sed 's|@.*||')"
  host="$(printf '%s' "$SENTRY_DSN" | sed 's|.*@||' | sed 's|/.*||')"
  project="$(printf '%s' "$SENTRY_DSN" | sed 's|.*/||')"
  timestamp="$(ts)"
  event_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

  curl -s --max-time 5 -X POST \
    "https://${host}/api/${project}/store/" \
    -H "Content-Type: application/json" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_client=molly-synthetic/1.0, sentry_timestamp=$(date +%s), sentry_key=${key}" \
    -d "{\"event_id\":\"${event_id}\",\"timestamp\":\"${timestamp}\",\"level\":\"error\",\"message\":\"${message}\",\"platform\":\"other\",\"logger\":\"molly-synthetic-monitor\",\"tags\":{\"service\":\"molly-api\",\"check\":\"synthetic\"}}" \
    >/dev/null 2>&1 || log "WARN: Sentry report failed (continuing)"
}

# ── Consecutive failure tracking ──────────────────────────────────────────────

read_failure_count() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

write_failure_count() {
  printf '%s\n' "$1" > "$STATE_FILE"
}

# ── Prometheus output ─────────────────────────────────────────────────────────

emit_prometheus() {
  local consecutive_failures="$1"
  local epoch_ms
  epoch_ms=$(now_ms)
  local i name status latency

  {
    echo "# HELP molly_synthetic_up Check result: 1=ok, 0=degraded, -=skipped"
    echo "# TYPE molly_synthetic_up gauge"
    for i in "${!CHECKS[@]}"; do
      name="${CHECKS[$i]}"
      status="${STATUSES[$i]}"
      [[ "$status" == "-" ]] && continue
      echo "molly_synthetic_up{check=\"${name}\"} ${status} ${epoch_ms}"
    done

    echo ""
    echo "# HELP molly_synthetic_latency_ms Round-trip latency in milliseconds"
    echo "# TYPE molly_synthetic_latency_ms gauge"
    for i in "${!CHECKS[@]}"; do
      name="${CHECKS[$i]}"
      latency="${LATENCIES[$i]}"
      [[ "${STATUSES[$i]}" == "-" ]] && continue
      echo "molly_synthetic_latency_ms{check=\"${name}\"} ${latency} ${epoch_ms}"
    done

    echo ""
    echo "# HELP molly_synthetic_consecutive_failures Consecutive failure run count"
    echo "# TYPE molly_synthetic_consecutive_failures gauge"
    echo "molly_synthetic_consecutive_failures ${consecutive_failures} ${epoch_ms}"
  } | tee -a "${PROM_FILE:-/dev/null}"
}

# ── Checks ────────────────────────────────────────────────────────────────────

log "═══════════════════════════════════════════════════════════"
log " molly synthetic monitor — ${MOLLY_API_URL}"
log "═══════════════════════════════════════════════════════════"

info "Check 1: GET /health"
http_check "health" "${MOLLY_API_URL}/health"

info "Check 2: GET /ready"
http_check "ready" "${MOLLY_API_URL}/ready"

info "Check 3: GET /v1/sky/today"
http_check "sky_today" "${MOLLY_API_URL}/v1/sky/today"

info "Check 4: chat round-trip"
if [[ "${NODE_ENV:-}" == "production" ]]; then
  log "  SKIP  chat_roundtrip (NODE_ENV=production — skipping to avoid live PII)"
  record_check "chat_roundtrip" "-" 0
else
  CHAT_OK=1
  CHAT_START=$(now_ms)
  TOKEN=""
  CONV_ID=""

  # dev-login
  LOGIN_RESP=$(curl -s --max-time "$CURL_TIMEOUT" \
    -X POST "${MOLLY_API_URL}/v1/auth/dev-login" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null) || { CHAT_OK=0; LOGIN_RESP=""; }

  if [[ "$CHAT_OK" == "1" ]]; then
    TOKEN=$(printf '%s' "$LOGIN_RESP" | jq -r '.accessToken // empty' 2>/dev/null || true)
    [[ -z "$TOKEN" ]] && CHAT_OK=0
  fi

  # create conversation
  if [[ "$CHAT_OK" == "1" ]]; then
    CONV_RESP=$(curl -s --max-time "$CURL_TIMEOUT" \
      -X POST "${MOLLY_API_URL}/v1/conversations" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      2>/dev/null) || { CHAT_OK=0; CONV_RESP=""; }

    if [[ "$CHAT_OK" == "1" ]]; then
      CONV_ID=$(printf '%s' "$CONV_RESP" | jq -r '.conversation.id // empty' 2>/dev/null || true)
      [[ -z "$CONV_ID" ]] && CHAT_OK=0
    fi
  fi

  # send message — verify SSE stream opens (data: line appears within timeout)
  if [[ "$CHAT_OK" == "1" ]]; then
    SSE_SNIPPET=$(curl -s -N --max-time "$CHAT_TIMEOUT" \
      -X POST "${MOLLY_API_URL}/v1/conversations/${CONV_ID}/messages" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"content":"What is the current moon phase?"}' \
      2>/dev/null | head -c 4096 || true)

    printf '%s\n' "$SSE_SNIPPET" | grep -q '^data:' || CHAT_OK=0
  fi

  CHAT_END=$(now_ms)
  CHAT_LATENCY=$((CHAT_END - CHAT_START))

  if [[ "$CHAT_OK" == "1" ]]; then
    record_check "chat_roundtrip" 1 "$CHAT_LATENCY"
  else
    log "  FAIL  chat_roundtrip: round-trip did not complete" >&2
    record_check "chat_roundtrip" 0 "$CHAT_LATENCY"
  fi
fi

# ── Consecutive failure count + paging ───────────────────────────────────────

PREV_FAILURES=$(read_failure_count)

if [[ "$OVERALL_OK" == "1" ]]; then
  CONSECUTIVE_FAILURES=0
  write_failure_count 0
  log "All checks passed — consecutive failure count reset to 0"
else
  CONSECUTIVE_FAILURES=$((PREV_FAILURES + 1))
  write_failure_count "$CONSECUTIVE_FAILURES"
  log "DEGRADED — consecutive failure count: ${CONSECUTIVE_FAILURES}/${FAIL_THRESHOLD}"

  if [[ "$CONSECUTIVE_FAILURES" -ge "$FAIL_THRESHOLD" ]]; then
    log "PAGING — threshold reached (${CONSECUTIVE_FAILURES} consecutive failures)"
    send_sentry_event "molly-api synthetic monitor: ${CONSECUTIVE_FAILURES} consecutive failures (threshold: ${FAIL_THRESHOLD})"
  fi
fi

# ── Prometheus output ─────────────────────────────────────────────────────────

log "───────────────────────────────────────────────────────────"
log " Prometheus metrics"
log "───────────────────────────────────────────────────────────"
emit_prometheus "$CONSECUTIVE_FAILURES"

# ── Exit ──────────────────────────────────────────────────────────────────────

if [[ "$OVERALL_OK" == "1" ]]; then
  log "═══════════════════════════════════════════════════════════"
  log " SYNTHETIC MONITOR PASSED"
  log "═══════════════════════════════════════════════════════════"
  exit 0
else
  log "═══════════════════════════════════════════════════════════"
  log " SYNTHETIC MONITOR FAILED"
  log "═══════════════════════════════════════════════════════════"
  exit 1
fi
