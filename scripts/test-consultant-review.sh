#!/usr/bin/env bash
# test-consultant-review.sh — Phase 4 gate verification for consultant review system
#
# Verifies that all 3 consultant agents are properly defined, all system prompts
# exist, the review protocol is documented with the gate mechanism, and the
# mol-review-gate formula is correctly structured.
#
# Exit 0 = all pass. Each failure prints FAIL with details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

assert_file_exists() {
    local label="$1"
    local path="${REPO_ROOT}/$2"
    if [[ -f "${path}" ]]; then
        echo "PASS  ${label}"
        PASS=$((PASS + 1))
    else
        echo "FAIL  ${label}"
        echo "      missing: ${path}"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_contains() {
    local label="$1"
    local path="${REPO_ROOT}/$2"
    local pattern="$3"
    if [[ -f "${path}" ]] && grep -q "${pattern}" "${path}"; then
        echo "PASS  ${label}"
        PASS=$((PASS + 1))
    else
        echo "FAIL  ${label}"
        echo "      file:    ${path}"
        echo "      pattern: ${pattern}"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_min_size() {
    local label="$1"
    local path="${REPO_ROOT}/$2"
    local min_bytes="$3"
    local size
    if [[ -f "${path}" ]]; then
        size=$(wc -c < "${path}")
        if [[ "${size}" -ge "${min_bytes}" ]]; then
            echo "PASS  ${label}"
            PASS=$((PASS + 1))
        else
            echo "FAIL  ${label}"
            echo "      file:      ${path}"
            echo "      expected:  >= ${min_bytes} bytes"
            echo "      got:       ${size} bytes"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL  ${label}"
        echo "      missing: ${path}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== consultant review system — Phase 4 gate verification ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "--- 1. Agent definitions ---"
echo

for consultant in ux sre quality; do
    agent_path="agents/${consultant}-consultant.md"

    assert_file_exists \
        "${consultant}-consultant: file exists" \
        "${agent_path}"

    assert_file_contains \
        "${consultant}-consultant: has Agent header" \
        "${agent_path}" \
        "^# Agent: ${consultant}-consultant"

    assert_file_contains \
        "${consultant}-consultant: has Role section" \
        "${agent_path}" \
        "^## Role"

    assert_file_contains \
        "${consultant}-consultant: has Inputs section" \
        "${agent_path}" \
        "^## Inputs"

    assert_file_contains \
        "${consultant}-consultant: has Output section" \
        "${agent_path}" \
        "^## Output"

    assert_file_contains \
        "${consultant}-consultant: documents P0 severity" \
        "${agent_path}" \
        "P0"

    assert_file_contains \
        "${consultant}-consultant: documents gate impact" \
        "${agent_path}" \
        "Blocks merge"

    echo
done

# ─────────────────────────────────────────────────────────────────────────────
echo "--- 2. System prompts ---"
echo

for consultant in ux sre quality; do
    prompt_path="prompts/consultants/${consultant}-system.md"

    assert_file_exists \
        "${consultant}-system: file exists" \
        "${prompt_path}"

    assert_file_min_size \
        "${consultant}-system: has substantial content (>= 500 bytes)" \
        "${prompt_path}" \
        500
done
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "--- 3. Review protocol documentation ---"
echo

PROTOCOL_PATH="docs/consultant-review-protocol.md"

assert_file_exists \
    "protocol doc: file exists" \
    "${PROTOCOL_PATH}"

assert_file_contains \
    "protocol doc: documents all three consultants" \
    "${PROTOCOL_PATH}" \
    "ux-consultant"

assert_file_contains \
    "protocol doc: has Tiered Intensity section" \
    "${PROTOCOL_PATH}" \
    "## Tiered Intensity"

assert_file_contains \
    "protocol doc: has Gate Mechanism section" \
    "${PROTOCOL_PATH}" \
    "## Gate Mechanism"

assert_file_contains \
    "protocol doc: documents bd dep add gate wiring" \
    "${PROTOCOL_PATH}" \
    "bd dep add"

assert_file_contains \
    "protocol doc: documents P0 severity (blocks gate)" \
    "${PROTOCOL_PATH}" \
    "P0"

assert_file_contains \
    "protocol doc: documents P1 severity (blocks gate)" \
    "${PROTOCOL_PATH}" \
    "P1"

assert_file_contains \
    "protocol doc: documents gate pass criteria" \
    "${PROTOCOL_PATH}" \
    "passes when"

echo

# ─────────────────────────────────────────────────────────────────────────────
echo "--- 4. mol-review-gate formula ---"
echo

FORMULA_PATH="formulas/mol-review-gate.formula.toml"

assert_file_exists \
    "formula: file exists" \
    "${FORMULA_PATH}"

assert_file_contains \
    "formula: has load-context step" \
    "${FORMULA_PATH}" \
    'id = "load-context"'

assert_file_contains \
    "formula: has classify-intensity step" \
    "${FORMULA_PATH}" \
    'id = "classify-intensity"'

assert_file_contains \
    "formula: has dispatch-reviews step" \
    "${FORMULA_PATH}" \
    'id = "dispatch-reviews"'

assert_file_contains \
    "formula: has collect-findings step" \
    "${FORMULA_PATH}" \
    'id = "collect-findings"'

assert_file_contains \
    "formula: has apply-gate-mechanism step" \
    "${FORMULA_PATH}" \
    'id = "apply-gate-mechanism"'

assert_file_contains \
    "formula: has assess-gate step" \
    "${FORMULA_PATH}" \
    'id = "assess-gate"'

assert_file_contains \
    "formula: has close-gate step" \
    "${FORMULA_PATH}" \
    'id = "close-gate"'

assert_file_contains \
    "formula: documents bd dep add gate mechanism" \
    "${FORMULA_PATH}" \
    "bd dep add"

assert_file_contains \
    "formula: documents tiered intensity" \
    "${FORMULA_PATH}" \
    "artifact_type"

echo

# ─────────────────────────────────────────────────────────────────────────────
echo "=== results ==="
echo
echo "PASS: ${PASS}"
echo "FAIL: ${FAIL}"
echo

if [[ "${FAIL}" -eq 0 ]]; then
    echo "Phase 4 gate: PASS"
    echo "All ${PASS} checks passed. Consultant review system is correctly defined."
    exit 0
else
    echo "Phase 4 gate: FAIL"
    echo "${FAIL} check(s) failed. See above for details."
    exit 1
fi
