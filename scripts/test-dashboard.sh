#!/usr/bin/env bash
# test-dashboard.sh — Phase 6 gate verification for the Victory dashboard
#
# Verifies that:
#   1. Dashboard server starts on :3456
#   2. Root page returns HTML with HTMX + SSE setup
#   3. /routes/projects returns project-card HTML
#   4. /routes/agents returns agent-row HTML (data-table)
#   5. /routes/beads returns bead-table HTML
#   6. /routes/escalations returns escalations HTML
#   7. /api/live SSE stream emits named events: projects, agents, beads, escalations
#
# Exit 0 = all pass. Each failure prints FAIL with details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DASHBOARD_DIR="${REPO_ROOT}/dashboard"

PORT=3456
BASE_URL="http://localhost:${PORT}"

PASS=0
FAIL=0
SERVER_PID=""

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

assert_contains() {
    local label="$1"
    local body="$2"
    local pattern="$3"
    if echo "${body}" | grep -q "${pattern}"; then
        echo "PASS  ${label}"
        PASS=$((PASS + 1))
    else
        echo "FAIL  ${label}"
        echo "      pattern not found: ${pattern}"
        echo "      body snippet: $(echo "${body}" | head -3)"
        FAIL=$((FAIL + 1))
    fi
}

assert_http_ok() {
    local label="$1"
    local url="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null)
    if [[ "${code}" == "200" ]]; then
        echo "PASS  ${label} (HTTP ${code})"
        PASS=$((PASS + 1))
    else
        echo "FAIL  ${label} (HTTP ${code})"
        FAIL=$((FAIL + 1))
    fi
}

cleanup() {
    if [[ -n "${SERVER_PID}" ]]; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# 1. Server startup
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Victory Dashboard — Phase 6 gate verification ==="
echo

echo "--- 1. Server startup ---"
echo

# Kill any existing process on 3456
lsof -ti:"${PORT}" | xargs kill -9 2>/dev/null || true
sleep 0.5

# Start the dashboard
cd "${DASHBOARD_DIR}"
bun run src/index.ts >/dev/null 2>&1 &
SERVER_PID=$!

# Wait up to 10s for server to be ready
READY=0
for i in $(seq 1 20); do
    if curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/" 2>/dev/null | grep -q "200"; then
        READY=1
        break
    fi
    sleep 0.5
done

if [[ "${READY}" -eq 1 ]]; then
    echo "PASS  server starts on :${PORT}"
    PASS=$((PASS + 1))
else
    echo "FAIL  server did not start on :${PORT} within 10s"
    FAIL=$((FAIL + 1))
    echo
    echo "=== RESULT: ${PASS} passed, ${FAIL} failed ==="
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Root page
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "--- 2. Root page ---"
echo

ROOT_BODY=$(curl -s "${BASE_URL}/")

assert_http_ok "GET / returns 200" "${BASE_URL}/"
assert_contains "root: has HTMX script tag" "${ROOT_BODY}" "htmx"
assert_contains "root: has SSE extension" "${ROOT_BODY}" "sse"
assert_contains "root: has SSE connect to /api/live" "${ROOT_BODY}" "sse-connect"
assert_contains "root: has projects panel" "${ROOT_BODY}" "panel-projects"
assert_contains "root: has agents panel" "${ROOT_BODY}" "panel-agents"
assert_contains "root: has beads panel" "${ROOT_BODY}" "panel-beads"
assert_contains "root: has escalations panel" "${ROOT_BODY}" "panel-escalations"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Projects route
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "--- 3. /routes/projects ---"
echo

assert_http_ok "GET /routes/projects returns 200" "${BASE_URL}/routes/projects"
PROJ_BODY=$(curl -s "${BASE_URL}/routes/projects")
assert_contains "projects: returns project-list container" "${PROJ_BODY}" "project-list\|project-card\|empty"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Agents route
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "--- 4. /routes/agents ---"
echo

assert_http_ok "GET /routes/agents returns 200" "${BASE_URL}/routes/agents"
AGENTS_BODY=$(curl -s "${BASE_URL}/routes/agents")
assert_contains "agents: returns data-table or empty" "${AGENTS_BODY}" "data-table\|agent-row\|empty"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Beads route
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "--- 5. /routes/beads ---"
echo

assert_http_ok "GET /routes/beads returns 200" "${BASE_URL}/routes/beads"
BEADS_BODY=$(curl -s "${BASE_URL}/routes/beads")
assert_contains "beads: returns data-table or empty" "${BEADS_BODY}" "data-table\|bead-row\|empty"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Escalations route
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "--- 6. /routes/escalations ---"
echo

assert_http_ok "GET /routes/escalations returns 200" "${BASE_URL}/routes/escalations"
ESC_BODY=$(curl -s "${BASE_URL}/routes/escalations")
assert_contains "escalations: returns content or empty" "${ESC_BODY}" "escalation\|empty"

# ─────────────────────────────────────────────────────────────────────────────
# 7. SSE /api/live
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "--- 7. SSE /api/live ---"
echo

# Capture 3 seconds of SSE output (--max-time exits after timeout, that's expected)
SSE_OUTPUT=$(curl -s -N --max-time 3 "${BASE_URL}/api/live" 2>/dev/null || true)

assert_contains "SSE: stream is reachable" "${SSE_OUTPUT}" "event:\|data:"
assert_contains "SSE: emits 'projects' event" "${SSE_OUTPUT}" "event: projects"
assert_contains "SSE: emits 'agents' event" "${SSE_OUTPUT}" "event: agents"
assert_contains "SSE: emits 'beads' event" "${SSE_OUTPUT}" "event: beads"
assert_contains "SSE: emits 'escalations' event" "${SSE_OUTPUT}" "event: escalations"

# ─────────────────────────────────────────────────────────────────────────────
# Result
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "=== RESULT: ${PASS} passed, ${FAIL} failed ==="

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
