#!/usr/bin/env bash
# scripts/install.sh
# Install the victory pack: dependencies, migrations, and preflight checks.
#
# Run this after cloning or updating the victory pack to ensure all
# prerequisites and database schemas are in place.
#
# Usage:
#   ./scripts/install.sh [--dry-run] [--skip-migrations]
#
# Options:
#   --dry-run           Show what would be done without making changes
#   --skip-migrations   Skip Dolt schema migrations (use if Dolt isn't running)
#
# Environment:
#   GT_ROOT             Gas Town root directory (default: ~/gt)
#   DOLT_DB             Target database name (default: victory)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(dirname "$SCRIPT_DIR")"

GT_ROOT="${GT_ROOT:-${HOME}/gt}"
DOLT_DB="${DOLT_DB:-victory}"

DRY_RUN=0
SKIP_MIGRATIONS=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)           DRY_RUN=1 ;;
        --skip-migrations)   SKIP_MIGRATIONS=1 ;;
        --help|-h)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

hr() { printf '%0.s─' {1..60}; echo; }
step() { echo; echo "── $*"; }
ok()   { echo "   ✓ $*"; }
warn() { echo "   ⚠ $*" >&2; }
fail() { echo "   ✗ $*" >&2; exit 1; }
dry()  { echo "   [dry-run] $*"; }

echo
echo "Victory pack installer"
echo "  Pack   : ${PACK_DIR}"
echo "  GT_ROOT: ${GT_ROOT}"
echo "  DB     : ${DOLT_DB}"
[[ $DRY_RUN -eq 1 ]] && echo "  Mode   : DRY RUN (no changes)"
hr

# ── Step 1: Verify required tools ───────────────────────────────────────────
step "Checking prerequisites"

check_tool() {
    local tool="$1"
    local install_hint="${2:-}"
    if command -v "$tool" &>/dev/null; then
        ok "$tool found ($(command -v "$tool"))"
    else
        if [[ -n "$install_hint" ]]; then
            fail "$tool not found — $install_hint"
        else
            fail "$tool not found"
        fi
    fi
}

check_tool bun   "install from https://bun.sh"
check_tool git   "install git"
check_tool dolt  "install from https://github.com/dolthub/dolt" || true

if ! command -v dolt &>/dev/null; then
    warn "dolt not found — schema migrations will be skipped"
    SKIP_MIGRATIONS=1
fi

# ── Step 2: Install dashboard dependencies ──────────────────────────────────
step "Installing dashboard dependencies (bun install)"

DASHBOARD_DIR="${PACK_DIR}/dashboard"

if [[ ! -f "${DASHBOARD_DIR}/package.json" ]]; then
    fail "Dashboard package.json not found at ${DASHBOARD_DIR}/package.json"
fi

if [[ $DRY_RUN -eq 1 ]]; then
    dry "cd ${DASHBOARD_DIR} && bun install"
else
    (cd "${DASHBOARD_DIR}" && bun install --frozen-lockfile 2>&1 | sed 's/^/   /')
    ok "dashboard dependencies installed"
fi

# ── Step 3: Validate pack structure ─────────────────────────────────────────
step "Validating pack structure"

REQUIRED_DIRS=(agents formulas orders prompts config dashboard schemas scripts)
for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "${PACK_DIR}/${dir}" ]]; then
        ok "${dir}/"
    else
        warn "Expected directory missing: ${dir}/"
    fi
done

REQUIRED_FILES=(pack.toml city.toml)
for file in "${REQUIRED_FILES[@]}"; do
    if [[ -f "${PACK_DIR}/${file}" ]]; then
        ok "${file}"
    else
        warn "Expected file missing: ${file}"
    fi
done

# ── Step 4: Run schema migrations ───────────────────────────────────────────
step "Schema migrations"

if [[ $SKIP_MIGRATIONS -eq 1 ]]; then
    warn "Skipping migrations (--skip-migrations or dolt not available)"
else
    MIGRATE_SCRIPT="${SCRIPT_DIR}/migrate.sh"
    if [[ ! -x "$MIGRATE_SCRIPT" ]]; then
        fail "migrate.sh not found or not executable at ${MIGRATE_SCRIPT}"
    fi

    # Check Dolt server is reachable before attempting migration
    DOLT_PORT=3307
    if ! nc -z 127.0.0.1 "${DOLT_PORT}" 2>/dev/null; then
        warn "Dolt server not reachable on port ${DOLT_PORT} — skipping migrations"
        warn "Run 'gt dolt start' to start Dolt, then re-run install.sh"
    else
        if [[ $DRY_RUN -eq 1 ]]; then
            dry "${MIGRATE_SCRIPT} --dry-run"
        else
            GT_ROOT="${GT_ROOT}" DOLT_DB="${DOLT_DB}" \
                "${MIGRATE_SCRIPT}" 2>&1 | sed 's/^/   /'
            ok "migrations complete"
        fi
    fi
fi

# ── Step 5: Register rig-level plugins ──────────────────────────────────────
step "Registering rig-level plugins"

PLUGINS_SRC="${PACK_DIR}/plugins"
PLUGINS_DEST="${GT_ROOT}/victory/plugins"

if [[ ! -d "${PLUGINS_SRC}" ]]; then
    ok "no plugins directory found — skipping"
else
    plugin_count=0
    for plugin_dir in "${PLUGINS_SRC}"/*/; do
        [[ -d "$plugin_dir" ]] || continue
        plugin_name="$(basename "$plugin_dir")"
        dest="${PLUGINS_DEST}/${plugin_name}"
        if [[ $DRY_RUN -eq 1 ]]; then
            dry "Would register plugin: ${plugin_name} → ${dest}/"
        else
            mkdir -p "${PLUGINS_DEST}"
            if [[ -d "$dest" ]]; then
                cp -r "${plugin_dir}/." "${dest}/"
                ok "updated plugin: ${plugin_name}"
            else
                cp -r "${plugin_dir}" "${dest}"
                ok "registered plugin: ${plugin_name}"
            fi
        fi
        plugin_count=$((plugin_count + 1))
    done
    if [[ $plugin_count -eq 0 ]]; then
        ok "plugins directory exists but is empty — nothing to register"
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo
hr
echo "Victory pack installed."
echo
echo "Next steps:"
echo "  Start dashboard : ./scripts/dashboard.sh start"
echo "  Run smoke test  : ./scripts/smoke-test.sh"
echo
