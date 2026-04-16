#!/usr/bin/env bash
# scripts/dashboard.sh
# Manage the Victory dashboard server (start / stop / status / logs).
#
# The dashboard runs a Bun/Hono server on port 3456, polling the Dolt
# database every 5 seconds and pushing live updates to browsers via SSE.
#
# Usage:
#   ./scripts/dashboard.sh start    Start the dashboard (background)
#   ./scripts/dashboard.sh stop     Stop the dashboard
#   ./scripts/dashboard.sh status   Show running state and URL
#   ./scripts/dashboard.sh restart  Stop then start
#   ./scripts/dashboard.sh logs     Tail dashboard logs
#   ./scripts/dashboard.sh run      Run in foreground (for dev/debugging)
#
# Environment:
#   GT_ROOT     Gas Town root directory (default: ~/gt)
#   DASHBOARD_PORT  Port to listen on (default: 3456)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(dirname "$SCRIPT_DIR")"
DASHBOARD_DIR="${PACK_DIR}/dashboard"

GT_ROOT="${GT_ROOT:-${HOME}/gt}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3456}"

RUNTIME_DIR="${GT_ROOT}/.runtime"
PID_FILE="${RUNTIME_DIR}/victory-dashboard.pid"
LOG_FILE="${RUNTIME_DIR}/victory-dashboard.log"

COMMAND="${1:-status}"

# ── Helpers ──────────────────────────────────────────────────────────────────

is_running() {
    if [[ ! -f "$PID_FILE" ]]; then
        return 1
    fi
    local pid
    pid="$(cat "$PID_FILE")"
    if [[ -z "$pid" ]]; then
        return 1
    fi
    kill -0 "$pid" 2>/dev/null
}

get_pid() {
    cat "$PID_FILE" 2>/dev/null || echo ""
}

ensure_runtime_dir() {
    mkdir -p "$RUNTIME_DIR"
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_start() {
    if is_running; then
        echo "Dashboard already running (pid=$(get_pid)) on http://localhost:${DASHBOARD_PORT}"
        return 0
    fi

    ensure_runtime_dir

    if [[ ! -f "${DASHBOARD_DIR}/package.json" ]]; then
        echo "ERROR: Dashboard not found at ${DASHBOARD_DIR}" >&2
        echo "       Run ./scripts/install.sh first." >&2
        exit 1
    fi

    if ! command -v bun &>/dev/null; then
        echo "ERROR: bun not found — install from https://bun.sh" >&2
        exit 1
    fi

    echo "Starting Victory dashboard on port ${DASHBOARD_PORT}..."

    # Start in background, redirect stdio to log file
    DASHBOARD_PORT="${DASHBOARD_PORT}" \
    GT_ROOT="${GT_ROOT}" \
        nohup bun run "${DASHBOARD_DIR}/src/index.ts" \
        >> "$LOG_FILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$PID_FILE"

    # Wait briefly and verify it stayed up
    sleep 1
    if ! is_running; then
        echo "ERROR: Dashboard failed to start. Check logs:" >&2
        echo "       ${LOG_FILE}" >&2
        rm -f "$PID_FILE"
        exit 1
    fi

    echo "Dashboard started (pid=${pid})"
    echo "  URL : http://localhost:${DASHBOARD_PORT}"
    echo "  Log : ${LOG_FILE}"
}

cmd_stop() {
    if ! is_running; then
        echo "Dashboard is not running."
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid="$(get_pid)"
    echo "Stopping dashboard (pid=${pid})..."

    kill "$pid" 2>/dev/null || true

    # Wait up to 5s for clean shutdown
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 5 ]]; do
        sleep 1
        ((waited++))
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "Process did not stop cleanly — sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    echo "Dashboard stopped."
}

cmd_status() {
    if is_running; then
        local pid
        pid="$(get_pid)"
        echo "Dashboard is RUNNING"
        echo "  PID : ${pid}"
        echo "  URL : http://localhost:${DASHBOARD_PORT}"
        echo "  Log : ${LOG_FILE}"

        # Quick health check
        if command -v curl &>/dev/null; then
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                --max-time 2 "http://localhost:${DASHBOARD_PORT}/" 2>/dev/null || echo "ERR")
            if [[ "$http_code" == "200" ]]; then
                echo "  Health: OK (HTTP 200)"
            else
                echo "  Health: HTTP ${http_code} (may still be starting)"
            fi
        fi
    else
        echo "Dashboard is STOPPED"
        rm -f "$PID_FILE"
    fi
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "No log file found at ${LOG_FILE}"
        echo "Start the dashboard first: $0 start"
        exit 1
    fi
    echo "==> ${LOG_FILE} (Ctrl-C to stop)"
    tail -f "$LOG_FILE"
}

cmd_run() {
    echo "Starting Victory dashboard in foreground (port ${DASHBOARD_PORT})..."
    echo "  Ctrl-C to stop"
    echo
    DASHBOARD_PORT="${DASHBOARD_PORT}" \
    GT_ROOT="${GT_ROOT}" \
        bun run "${DASHBOARD_DIR}/src/index.ts"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$COMMAND" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    status)  cmd_status  ;;
    restart) cmd_restart ;;
    logs)    cmd_logs    ;;
    run)     cmd_run     ;;
    --help|-h)
        sed -n '2,18p' "$0"
        exit 0
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        echo "Usage: $0 {start|stop|status|restart|logs|run}" >&2
        exit 1
        ;;
esac
