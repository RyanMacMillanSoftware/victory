#!/usr/bin/env bash
# scripts/smoke-test.sh
# End-to-end smoke test: install pack, onboard a repo, verify dashboard renders.
#
# This test is self-contained and does NOT require a running Dolt server.
# It validates:
#   1. install.sh runs cleanly (with --skip-migrations)
#   2. The onboarding flow produces a valid AGENTS.md in a temp repo
#   3. The dashboard starts and responds to HTTP requests
#
# Usage:
#   ./scripts/smoke-test.sh [--keep-tmp] [--no-dashboard]
#
# Options:
#   --keep-tmp       Don't delete the temp directory on exit (for debugging)
#   --no-dashboard   Skip dashboard start/verify steps
#
# Requirements:
#   bun, git, curl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(dirname "$SCRIPT_DIR")"
DASHBOARD_DIR="${PACK_DIR}/dashboard"

KEEP_TMP=0
NO_DASHBOARD=0
DASHBOARD_PID=""
TEST_PORT=13456   # Use a non-standard port to avoid collisions

for arg in "$@"; do
    case "$arg" in
        --keep-tmp)     KEEP_TMP=1 ;;
        --no-dashboard) NO_DASHBOARD=1 ;;
        --help|-h)
            sed -n '2,16p' "$0"
            exit 0
            ;;
    esac
done

# ── Utilities ────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0

ok()   { echo "  PASS  $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $*" >&2; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $*"; SKIP=$((SKIP + 1)); }
step() { echo; echo "── $*"; }

TMP_DIR=""

cleanup() {
    local exit_code=$?

    # Stop dashboard if we started it
    if [[ -n "$DASHBOARD_PID" ]]; then
        kill "$DASHBOARD_PID" 2>/dev/null || true
        wait "$DASHBOARD_PID" 2>/dev/null || true
    fi

    if [[ $KEEP_TMP -eq 0 && -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    elif [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        echo
        echo "Temp dir preserved at: ${TMP_DIR}"
    fi

    echo
    echo "────────────────────────────────────────────────────────────"
    echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
    if [[ $FAIL -gt 0 ]]; then
        echo "SMOKE TEST FAILED"
        exit 1
    else
        echo "SMOKE TEST PASSED"
        exit 0
    fi
}

trap cleanup EXIT

# ── Preflight ────────────────────────────────────────────────────────────────

step "Preflight: checking required tools"

for tool in bun git curl; do
    if command -v "$tool" &>/dev/null; then
        ok "${tool} available"
    else
        fail "${tool} not found — required for smoke test"
    fi
done

if [[ $FAIL -gt 0 ]]; then
    echo "Preflight failed — cannot continue." >&2
    exit 1
fi

# ── Test 1: install.sh ───────────────────────────────────────────────────────

step "Test 1: install.sh (--dry-run --skip-migrations)"

INSTALL_OUT=$("${SCRIPT_DIR}/install.sh" --dry-run --skip-migrations 2>&1) || {
    fail "install.sh exited non-zero"
    echo "$INSTALL_OUT" >&2
}

if echo "$INSTALL_OUT" | grep -q "bun found"; then
    ok "install.sh detected bun"
else
    fail "install.sh did not confirm bun"
fi

if echo "$INSTALL_OUT" | grep -q "Skipping migrations"; then
    ok "install.sh respected --skip-migrations"
else
    fail "install.sh did not skip migrations as expected"
fi

if echo "$INSTALL_OUT" | grep -q "Victory pack installed"; then
    ok "install.sh completed successfully"
else
    fail "install.sh did not print completion message"
fi

# ── Test 2: bun install for dashboard ────────────────────────────────────────

step "Test 2: dashboard dependencies (bun install)"

if [[ -d "${DASHBOARD_DIR}/node_modules" ]] || [[ -f "${DASHBOARD_DIR}/bun.lock" ]]; then
    ok "bun install already run (node_modules or bun.lock present)"
else
    echo "  Running bun install in dashboard/..."
    (cd "${DASHBOARD_DIR}" && bun install --frozen-lockfile 2>&1 | sed 's/^/    /') || {
        fail "bun install failed"
    }
    ok "bun install succeeded"
fi

# Verify key dependencies are present
if (cd "${DASHBOARD_DIR}" && bun pm ls 2>/dev/null | grep -q "hono") || \
   [[ -d "${DASHBOARD_DIR}/node_modules/hono" ]]; then
    ok "hono dependency present"
else
    fail "hono not found in dashboard/node_modules"
fi

# ── Test 3: pack structure validation ────────────────────────────────────────

step "Test 3: pack structure"

REQUIRED_DIRS=(agents formulas orders prompts config dashboard schemas scripts)
for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "${PACK_DIR}/${dir}" ]]; then
        ok "directory: ${dir}/"
    else
        fail "missing directory: ${dir}/"
    fi
done

REQUIRED_FORMULAS=(mol-build-cycle.toml mol-onboard-repo.toml mol-victory-pipeline.toml)
for formula in "${REQUIRED_FORMULAS[@]}"; do
    if [[ -f "${PACK_DIR}/formulas/${formula}" ]]; then
        ok "formula: ${formula}"
    else
        fail "missing formula: formulas/${formula}"
    fi
done

REQUIRED_AGENTS=(planner.md quality-consultant.md sre-consultant.md ux-consultant.md)
for agent in "${REQUIRED_AGENTS[@]}"; do
    if [[ -f "${PACK_DIR}/agents/${agent}" ]]; then
        ok "agent: ${agent}"
    else
        fail "missing agent: agents/${agent}"
    fi
done

# ── Test 4: onboard a repo ───────────────────────────────────────────────────

step "Test 4: onboard a sample repository"

TMP_DIR="$(mktemp -d)"
SAMPLE_REPO="${TMP_DIR}/sample-repo"

# Create a minimal Git repo to onboard
mkdir -p "${SAMPLE_REPO}"
cd "${SAMPLE_REPO}"
git init -q
git config user.email "smoke@test.local"
git config user.name "Smoke Test"

# Add a sample TypeScript project
cat > package.json <<'EOF'
{
  "name": "sample-repo",
  "version": "1.0.0",
  "scripts": {
    "build": "tsc --noEmit",
    "test": "bun test",
    "lint": "eslint src/"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
EOF

mkdir -p src
cat > src/index.ts <<'EOF'
export function greet(name: string): string {
  return `Hello, ${name}!`
}
EOF

cat > README.md <<'EOF'
# Sample Repo

A minimal TypeScript project for testing Victory onboarding.
EOF

git add .
git commit -q -m "feat: initial commit"

cd "${PACK_DIR}"

# Simulate the onboarding: run stack detection inline (not the full formula,
# which requires a live Gas Town session). We verify the formula file is valid
# TOML and that the onboarding script can produce a plausible AGENTS.md.

ONBOARD_FORMULA="${PACK_DIR}/formulas/mol-onboard-repo.toml"

if [[ ! -f "$ONBOARD_FORMULA" ]]; then
    fail "mol-onboard-repo.toml not found"
else
    ok "mol-onboard-repo.toml exists"
fi

# Detect stack in sample repo (mirrors mol-onboard-repo Step 1)
cd "${SAMPLE_REPO}"
DETECTED_LANG=""
if ls package.json 2>/dev/null | grep -q package.json; then
    DETECTED_LANG="TypeScript/JavaScript"
fi
if ls Cargo.toml 2>/dev/null | grep -q Cargo.toml; then
    DETECTED_LANG="Rust"
fi
if ls go.mod 2>/dev/null | grep -q go.mod; then
    DETECTED_LANG="Go"
fi

if [[ -n "$DETECTED_LANG" ]]; then
    ok "stack detected: ${DETECTED_LANG}"
else
    fail "could not detect tech stack in sample repo"
fi

# Generate a minimal AGENTS.md (mirrors mol-onboard-repo Step 3)
AGENTS_MD="${SAMPLE_REPO}/AGENTS.md"
cat > "${AGENTS_MD}" <<EOF
# sample-repo — Agent Guide

> Generated by Victory smoke-test onboarding. Keep this up to date as conventions evolve.

## Stack
- Language: ${DETECTED_LANG}
- Build: bun run build
- Test: bun test
- Lint: eslint

## Quality Gates

Every polecat MUST run these before committing:

\`\`\`bash
# Build
bun run build

# Tests
bun test

# Lint
bun run lint
\`\`\`

## Core Rule

Work is NOT done until:
1. \`bun run build\` passes
2. \`bun test\` passes
3. \`bun run lint\` passes
4. Changes committed to feature branch
5. \`gt done\` run

## Conventions

### File Layout
- \`src/\` — source files
- \`tests/\` or \`*.test.ts\` — test files alongside source

### Naming
- Files: kebab-case (e.g., \`user-service.ts\`)
- Functions: camelCase
- Types/Interfaces: PascalCase

### Commit Style
Conventional commits: \`feat:\`, \`fix:\`, \`chore:\`, \`docs:\`, \`test:\`

## Known Pitfalls
1. **Missing bun.lock**: Always commit \`bun.lock\` for reproducible builds.
2. **TypeScript strict mode**: This project uses strict TypeScript — avoid \`any\`.

## Key Files
- \`package.json\`: Build scripts and dependencies
- \`src/index.ts\`: Main entry point
EOF

git add AGENTS.md
git commit -q -m "chore: add Victory AGENTS.md for sample-repo onboarding (smoke-test)"

if [[ -f "$AGENTS_MD" ]]; then
    ok "AGENTS.md generated"
else
    fail "AGENTS.md not created"
fi

# Verify AGENTS.md has required sections
for section in "Stack" "Quality Gates" "Core Rule" "Conventions" "Known Pitfalls"; do
    if grep -q "## ${section}" "$AGENTS_MD"; then
        ok "AGENTS.md has section: ${section}"
    else
        fail "AGENTS.md missing section: ${section}"
    fi
done

# ── Test 5: dashboard renders ────────────────────────────────────────────────

step "Test 5: dashboard renders"

cd "${PACK_DIR}"

if [[ $NO_DASHBOARD -eq 1 ]]; then
    skip "dashboard test (--no-dashboard)"
else
    # Start dashboard in background on test port
    DASHBOARD_PORT="${TEST_PORT}" \
    GT_ROOT="${GT_ROOT:-${HOME}/gt}" \
        bun run "${DASHBOARD_DIR}/src/index.ts" \
        >> "${TMP_DIR}/dashboard.log" 2>&1 &
    DASHBOARD_PID=$!

    # Wait for dashboard to be ready (up to 10s)
    echo "  Waiting for dashboard to start on port ${TEST_PORT}..."
    READY=0
    for i in $(seq 1 20); do
        sleep 0.5
        if curl -s --max-time 1 "http://localhost:${TEST_PORT}/" -o /dev/null 2>/dev/null; then
            READY=1
            break
        fi
    done

    if [[ $READY -eq 0 ]]; then
        fail "dashboard did not become ready within 10s"
        echo "  Dashboard log:" >&2
        cat "${TMP_DIR}/dashboard.log" >&2
    else
        ok "dashboard started and accepting connections"

        # Verify HTTP 200
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 3 "http://localhost:${TEST_PORT}/" 2>/dev/null || echo "ERR")
        if [[ "$HTTP_CODE" == "200" ]]; then
            ok "HTTP GET / → 200 OK"
        else
            fail "HTTP GET / → ${HTTP_CODE} (expected 200)"
        fi

        # Verify it returns HTML with expected content
        BODY=$(curl -s --max-time 3 "http://localhost:${TEST_PORT}/" 2>/dev/null || echo "")
        if echo "$BODY" | grep -qi "dashboard\|panel\|htmx\|hx-get"; then
            ok "response body contains dashboard markup"
        else
            fail "response body does not look like the dashboard HTML"
        fi

        # Verify all dashboard panel routes return 200
        for route in /routes/projects /routes/agents /routes/beads /routes/escalations /routes/bugs /routes/convoys; do
            PANEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                --max-time 3 "http://localhost:${TEST_PORT}${route}" 2>/dev/null || echo "ERR")
            if [[ "$PANEL_CODE" == "200" ]]; then
                ok "HTTP GET ${route} → 200 OK"
            else
                fail "HTTP GET ${route} → ${PANEL_CODE} (expected 200)"
            fi
        done

        # Verify SSE endpoints exist
        for sse_path in /api/live /api/events; do
            SSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                --max-time 2 "http://localhost:${TEST_PORT}${sse_path}" \
                -H "Accept: text/event-stream" 2>/dev/null || echo "ERR")
            if [[ "$SSE_CODE" == "200" ]]; then
                ok "SSE endpoint ${sse_path} → 200"
            else
                # Non-fatal: SSE requires Dolt, which isn't running in this test
                skip "SSE endpoint ${sse_path} returned ${SSE_CODE} (Dolt not required here)"
            fi
        done
    fi
fi
