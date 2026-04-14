#!/usr/bin/env bash
# test-model-routing.sh — test cases for the model routing resolver
#
# Exercises all 6 resolution steps and verifies correct model selection.
# Exit 0 = all pass. Each failure prints FAIL with details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/model-routing.sh"
PASS=0
FAIL=0

assert_model() {
    local label="$1"
    local expected="$2"
    shift 2
    local got
    got=$("${RESOLVER}" "$@" 2>&1)
    if [[ "$got" == "$expected" ]]; then
        echo "PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $label"
        echo "      expected: $expected"
        echo "      got:      $got"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_field() {
    local label="$1"
    local field="$2"
    local expected="$3"
    shift 3
    local got
    got=$("${RESOLVER}" --json "$@" 2>&1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['${field}'])")
    if [[ "$got" == "$expected" ]]; then
        echo "PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $label"
        echo "      expected ${field}=${expected}"
        echo "      got      ${field}=${got}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== model-routing resolution tests ==="
echo

# Step 1: Explicit override (--override flag)
assert_model "step1: --override flag" \
    "claude-haiku-4-5-20251001" \
    --override "claude-haiku-4-5-20251001"

# Step 1: Explicit override (env var)
got=$(VICTORY_MODEL_OVERRIDE="claude-opus-4-6" "${RESOLVER}" 2>&1)
if [[ "$got" == "claude-opus-4-6" ]]; then
    echo "PASS  step1: VICTORY_MODEL_OVERRIDE env"
    PASS=$((PASS + 1))
else
    echo "FAIL  step1: VICTORY_MODEL_OVERRIDE env"
    echo "      expected: claude-opus-4-6"
    echo "      got:      $got"
    FAIL=$((FAIL + 1))
fi

# Step 1: --override takes precedence over --role
assert_model "step1: --override beats --role" \
    "claude-haiku-4-5-20251001" \
    --override "claude-haiku-4-5-20251001" --role mayor

# Step 2: P0 priority → deep (Opus)
assert_model "step2: P0 priority → opus" \
    "claude-opus-4-6" \
    --priority P0

# Step 2: P0 case-insensitive
assert_model "step2: p0 lowercase → opus" \
    "claude-opus-4-6" \
    --priority p0

# Step 2: Non-P0 priority does not trigger step 2
assert_model "step2: P1 does not trigger deep" \
    "claude-sonnet-4-6" \
    --priority P1

# Step 3: Bead type → fast (triage)
assert_model "step3: type=triage → haiku" \
    "claude-haiku-4-5-20251001" \
    --type triage

# Step 3: Bead type → fast (status_check)
assert_model "step3: type=status_check → haiku" \
    "claude-haiku-4-5-20251001" \
    --type status_check

# Step 3: Bead type → medium (implementation)
assert_model "step3: type=implementation → sonnet" \
    "claude-sonnet-4-6" \
    --type implementation

# Step 3: Bead type → deep (architecture)
assert_model "step3: type=architecture → opus" \
    "claude-opus-4-6" \
    --type architecture

# Step 3: Bead type → deep (debugging)
assert_model "step3: type=debugging → opus" \
    "claude-opus-4-6" \
    --type debugging

# Step 3: Bead type → deep (research)
assert_model "step3: type=research → opus" \
    "claude-opus-4-6" \
    --type research

# Step 4: Complexity — files > 5 → deep
assert_model "step4: files=6 → opus" \
    "claude-opus-4-6" \
    --files 6

# Step 4: Complexity — files == 5 does NOT trigger (threshold is strictly >)
assert_model "step4: files=5 does not escalate (role=polecat fallback)" \
    "claude-sonnet-4-6" \
    --files 5 --role polecat

# Step 4: Complexity — deps > 3 → deep
assert_model "step4: deps=4 → opus" \
    "claude-opus-4-6" \
    --deps 4

# Step 4: Complexity — deps == 3 does NOT trigger
assert_model "step4: deps=3 does not escalate (role=polecat fallback)" \
    "claude-sonnet-4-6" \
    --deps 3 --role polecat

# Step 4: Complexity — files=0, deps=0 does not trigger
assert_model "step4: files=0 deps=0 no escalation (role=polecat)" \
    "claude-sonnet-4-6" \
    --files 0 --deps 0 --role polecat

# Step 3 beats step 4: bead type matched → type wins, complexity not evaluated
# type=implementation (medium/sonnet) takes precedence over files=6 (complexity)
assert_model "step3 beats step4: type=implementation files=6 → sonnet" \
    "claude-sonnet-4-6" \
    --type implementation --files 6

# Step 5: Role default — polecat → medium (sonnet)
assert_model "step5: role=polecat → sonnet" \
    "claude-sonnet-4-6" \
    --role polecat

# Step 5: Role default — mayor → deep (opus)
assert_model "step5: role=mayor → opus" \
    "claude-opus-4-6" \
    --role mayor

# Step 5: Role default — refinery → fast (haiku)
assert_model "step5: role=refinery → haiku" \
    "claude-haiku-4-5-20251001" \
    --role refinery

# Step 5: Role default — deacon → fast (haiku)
assert_model "step5: role=deacon → haiku" \
    "claude-haiku-4-5-20251001" \
    --role deacon

# Step 6: Fallback — no inputs → sonnet (defaults.tier=medium)
assert_model "step6: no inputs → sonnet fallback" \
    "claude-sonnet-4-6"

# JSON output — verify all fields present
assert_json_field "json: step1 model field" "model" \
    "claude-haiku-4-5-20251001" \
    --override "claude-haiku-4-5-20251001"

assert_json_field "json: step1 tier field" "tier" \
    "override" \
    --override "claude-haiku-4-5-20251001"

assert_json_field "json: step2 tier field" "tier" \
    "deep" \
    --priority P0

assert_json_field "json: step4 tier field" "tier" \
    "deep" \
    --files 6

assert_json_field "json: step6 tier field" "tier" \
    "medium"

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
