#!/usr/bin/env bash
# tests/e2e/synthetic_monitor_test.sh
#
# Tests that synthetic-monitor.sh exits non-zero when the API is degraded.
# Starts a local mock HTTP server that returns 503 for all requests, then
# asserts the monitor detects failure and exits 1.
#
# Usage:
#   bash tests/e2e/synthetic_monitor_test.sh
#
# Requirements: bash, curl, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
MONITOR="${ROOT_DIR}/scripts/synthetic-monitor.sh"

MOCK_PORT=18923
MOCK_PID=""
STATE_FILE="/tmp/synthetic-monitor-test-state-$$"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗ FAIL:${NC} $*" >&2; exit 1; }
info() { echo -e "${YELLOW}→${NC} $*"; }

cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$STATE_FILE"
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────

info "Preflight checks"

[[ -f "$MONITOR" ]] || fail "Monitor script not found: $MONITOR"
command -v python3 >/dev/null 2>&1 || fail "python3 required for mock server"
command -v curl >/dev/null 2>&1    || fail "curl required"
pass "Preflight OK"

# ── Start mock HTTP server (always returns 503) ───────────────────────────────

info "Starting mock HTTP server on port ${MOCK_PORT} (always 503)"

python3 - <<EOF &
import http.server, socketserver, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Service Unavailable\n")
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(content_length)
        self.send_response(503)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Service Unavailable\n")
    def log_message(self, *args):
        pass  # suppress request logs

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", ${MOCK_PORT}), Handler) as srv:
    srv.serve_forever()
EOF
MOCK_PID=$!

# Wait for server to be ready
for i in $(seq 1 20); do
  if curl -sf --max-time 1 "http://127.0.0.1:${MOCK_PORT}/" >/dev/null 2>&1; then
    break
  fi
  # 503 also means server is up
  if curl --max-time 1 "http://127.0.0.1:${MOCK_PORT}/" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -q "503"; then
    break
  fi
  sleep 0.1
  [[ "$i" -eq 20 ]] && fail "Mock server did not start after 2s"
done
pass "Mock server running on port ${MOCK_PORT}"

# ── Test 1: monitor detects degraded API and exits non-zero ───────────────────

info "Test 1: synthetic-monitor exits non-zero for degraded API"

EXIT_CODE=0
MONITOR_OUTPUT=$(
  MOLLY_API_URL="http://127.0.0.1:${MOCK_PORT}" \
  NODE_ENV="development" \
  SENTRY_DSN="" \
  FAIL_THRESHOLD="3" \
  STATE_FILE="$STATE_FILE" \
  CURL_TIMEOUT="3" \
  CHAT_TIMEOUT="3" \
  bash "$MONITOR" 2>&1
) || EXIT_CODE=$?

if [[ "$EXIT_CODE" -ne 0 ]]; then
  pass "Monitor exited non-zero (${EXIT_CODE}) — correctly detected degradation"
else
  echo "$MONITOR_OUTPUT"
  fail "Monitor should have exited non-zero but exited 0"
fi

# ── Test 2: monitor output contains FAIL lines for health and ready ───────────

info "Test 2: output includes FAIL for /health and /ready checks"

echo "$MONITOR_OUTPUT" | grep -q "FAIL.*health" || \
  fail "Expected FAIL for 'health' check in output"
echo "$MONITOR_OUTPUT" | grep -q "FAIL.*ready" || \
  fail "Expected FAIL for 'ready' check in output"
pass "Output contains expected FAIL entries"

# ── Test 3: consecutive failure count increments ──────────────────────────────

info "Test 3: STATE_FILE records consecutive failure count"

[[ -f "$STATE_FILE" ]] || fail "STATE_FILE was not written"
COUNT=$(cat "$STATE_FILE")
[[ "$COUNT" -ge 1 ]] || fail "Expected failure count >= 1, got: ${COUNT}"
pass "Consecutive failure count: ${COUNT}"

# ── Test 4: Prometheus output includes degraded metrics ───────────────────────

info "Test 4: Prometheus output includes molly_synthetic_up metrics with 0 values"

echo "$MONITOR_OUTPUT" | grep -q 'molly_synthetic_up{check="health"} 0' || \
  fail "Expected molly_synthetic_up{check=\"health\"} 0 in output"
echo "$MONITOR_OUTPUT" | grep -q 'molly_synthetic_up{check="ready"} 0' || \
  fail "Expected molly_synthetic_up{check=\"ready\"} 0 in output"
pass "Prometheus output contains degraded metrics"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────────────────────────"
echo "All 4 synthetic monitor tests passed"
echo "────────────────────────────────────────────────────────────────"
exit 0
