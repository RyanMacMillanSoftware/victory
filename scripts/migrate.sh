#!/usr/bin/env bash
# scripts/migrate.sh
# Applies Victory pack schema migrations to the Dolt database.
#
# Run after deploying or updating the victory pack to ensure
# the database schema matches pack requirements. Idempotent.
#
# Usage:
#   ./scripts/migrate.sh [--dry-run]
#
# Environment:
#   GT_ROOT      Gas Town root directory (default: ~/gt)
#   DOLT_DB      Target database name (default: victory)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(dirname "$SCRIPT_DIR")"
SCHEMA_DIR="${PACK_DIR}/schemas"

GT_ROOT="${GT_ROOT:-${HOME}/gt}"
DOLT_DATA_DIR="${GT_ROOT}/.dolt-data"
DOLT_DB="${DOLT_DB:-victory}"
DB_DIR="${DOLT_DATA_DIR}/${DOLT_DB}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

dolt_sql() {
    dolt --data-dir "${DB_DIR}" sql "$@"
}

echo "==> Victory pack schema migrations"
echo "    Database : ${DOLT_DB}"
echo "    Data dir : ${DB_DIR}"
echo ""

if [[ ! -d "${DB_DIR}" ]]; then
    echo "ERROR: Dolt database directory not found: ${DB_DIR}" >&2
    exit 1
fi

# ── schemas/bug-memory.sql ──────────────────────────────────────────────────
echo "--> schemas/bug-memory.sql"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] would apply ${SCHEMA_DIR}/bug-memory.sql"
else
    dolt_sql < "${SCHEMA_DIR}/bug-memory.sql"
    echo "    applied"
fi

# ── Commit any schema changes ───────────────────────────────────────────────
if [[ $DRY_RUN -eq 0 ]]; then
    echo ""
    echo "--> Checking for uncommitted schema changes..."
    CHANGED=$(dolt_sql -q "SELECT COUNT(*) FROM dolt_status;" -r csv 2>/dev/null | tail -1 || echo "0")
    if [[ "${CHANGED}" -gt 0 ]]; then
        dolt_sql -q "CALL DOLT_ADD('-A');"
        dolt_sql -q "CALL DOLT_COMMIT('-m', 'chore: apply victory pack schema migrations (hq-zx6)');"
        echo "    committed"
    else
        echo "    no changes (schemas already up to date)"
    fi
fi

echo ""
echo "==> Done"
