#!/usr/bin/env bash
# scripts/bug-warn-inject.sh
#
# Query bug_memory for known bug patterns matching given file paths or patterns.
# Outputs up to 5 active warnings as a markdown block, suitable for appending
# to a polecat brief (prompts/polecat/brief.md) at sling time.
#
# Usage:
#   ./scripts/bug-warn-inject.sh [file-path-or-pattern...]
#   ./scripts/bug-warn-inject.sh "scripts/migrate.sh" "config/defaults.toml"
#   ./scripts/bug-warn-inject.sh "*.ts" "dashboard/src/index.ts"
#
#   # No patterns: return top 5 warnings by occurrence (broadcast mode)
#   ./scripts/bug-warn-inject.sh
#
# Output:
#   If matching warnings exist, prints a markdown ## section to stdout.
#   If no matches, exits silently with code 0.
#   Non-zero exit indicates an error (Dolt not available, etc.).
#
# Environment:
#   GT_ROOT     Gas Town root directory (default: ~/gt)
#   DOLT_DB     Target database (default: victory)
#   DOLT_DATA   Dolt data directory (default: $GT_ROOT/.dolt-data)

set -euo pipefail

GT_ROOT="${GT_ROOT:-${HOME}/gt}"
DOLT_DB="${DOLT_DB:-victory}"
DOLT_DATA="${DOLT_DATA:-${GT_ROOT}/.dolt-data}"
DB_DIR="${DOLT_DATA}/${DOLT_DB}"

# ── Preflight ────────────────────────────────────────────────────────────────

if [[ ! -d "${DB_DIR}" ]]; then
    # Database not provisioned — skip silently (not an error at sling time)
    exit 0
fi

if ! command -v dolt &>/dev/null; then
    echo "bug-warn-inject: dolt not found in PATH — skipping" >&2
    exit 0
fi

# ── Build SQL WHERE clause ───────────────────────────────────────────────────
#
# Matching strategy:
#   For each given file path/pattern, check if any stored file_pattern
#   (which is a glob like "scripts/*.sh") would match the given path.
#
#   SQL form:  'scripts/migrate.sh' LIKE REPLACE(file_pattern, '*', '%')
#
#   This means: if bug_memory has file_pattern='scripts/*.sh', and we pass
#   'scripts/migrate.sh', the LIKE comparison succeeds because:
#     'scripts/migrate.sh' LIKE 'scripts/%.sh'  → true
#
# When no patterns are given, we return the top 5 by occurrence_count.

build_conditions() {
    local -a patterns=("$@")

    if [[ ${#patterns[@]} -eq 0 ]]; then
        echo ""
        return
    fi

    local cond=""
    for path in "${patterns[@]}"; do
        # Escape SQL special characters in the given path
        local safe="${path//\'/\'\'}"
        # Escape SQL LIKE special chars (%, _) in the given path so they're
        # treated literally when we're matching the PATH against the pattern.
        safe="${safe//%/\\%}"
        safe="${safe//_/\\_}"

        if [[ -n "$cond" ]]; then
            cond="${cond} OR '${safe}' LIKE REPLACE(REPLACE(file_pattern, '*', '%'), '?', '_')"
        else
            cond="'${safe}' LIKE REPLACE(REPLACE(file_pattern, '*', '%'), '?', '_')"
        fi
    done

    echo "AND (${cond})"
}

PATTERN_COND=$(build_conditions "$@")

SQL="SELECT id, bug_title, warning_text, code_area, occurrence_count
FROM bug_memory
WHERE status = 'active'
  ${PATTERN_COND}
ORDER BY occurrence_count DESC
LIMIT 5;"

# ── Query ────────────────────────────────────────────────────────────────────

JSON=$(dolt --data-dir "${DB_DIR}" sql -q "${SQL}" -r json 2>/dev/null || echo '{"rows":[]}')

# ── Parse and format ─────────────────────────────────────────────────────────

python3 - "${JSON}" <<'PYEOF'
import json, sys

payload = json.loads(sys.argv[1])
rows = payload.get("rows", [])

if not rows:
    sys.exit(0)

print("## ⚠️ Bug Memory Warnings")
print("")
print("Known issues in files related to this task — review before implementing:")
print("")

for i, row in enumerate(rows, 1):
    title = row.get("bug_title", "").strip()
    warning = row.get("warning_text", "").strip()
    area = row.get("code_area", "").strip()
    count = row.get("occurrence_count", "1")

    print(f"### {i}. {title}")
    print("")
    if area:
        print(f"**Area:** `{area}` · **Seen:** {count}×")
        print("")
    print(warning)
    print("")
PYEOF
