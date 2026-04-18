# Victory Operator Guide

This guide walks a new operator through installing Victory, starting the dashboard,
and running a complete pipeline cycle from bead creation to merged code.

---

## 1. Prerequisites

Before installing Victory, ensure these tools are available on your system:

| Tool | Purpose | Install |
|------|---------|---------|
| `gt` (Gas Town) | Rig orchestration, bead management, sling dispatch | Follow the Gas Town install docs |
| `dolt` | Data plane for beads — runs on port 3307 | `brew install dolt` or [dolthub/dolt](https://github.com/dolthub/dolt) |
| `bun` | Dashboard server runtime | `curl -fsSL https://bun.sh/install | bash` |
| `git` | Source control | `brew install git` |
| `python3` | Model routing script (stdlib only) | Included on macOS / most Linux |

**Dolt must be running** before install if you want schema migrations to execute.
Start it with:

```bash
gt dolt start
gt dolt status     # Confirm latency < 5s and no orphan DBs
```

---

## 2. Installation

### Clone and install

```bash
# Clone the victory pack (or use your existing worktree)
git clone <victory-repo-url>
cd victory

# Run the installer
bash scripts/install.sh
```

The installer will:

1. Check that `bun`, `git`, and `dolt` are present
2. Run `bun install --frozen-lockfile` inside `dashboard/`
3. Validate the expected directory structure (`agents/`, `formulas/`, `orders/`, etc.)
4. Apply Dolt schema migrations via `scripts/migrate.sh` (skipped if Dolt is unreachable)

### Install options

```bash
bash scripts/install.sh --dry-run           # Preview actions without making changes
bash scripts/install.sh --skip-migrations   # Skip Dolt setup (use when Dolt is offline)
```

### Post-install smoke test

```bash
bash scripts/smoke-test.sh   # 42 checks; all must pass
```

The smoke test does not require a running Dolt server and is safe to run at any time.

---

## 3. Dashboard

### Starting the dashboard

```bash
bash scripts/dashboard.sh start
```

The dashboard runs a Bun + Hono server on **port 3456**, polling Dolt every 5 seconds
and pushing live updates to browsers via SSE.

### Visiting the dashboard

Open **http://localhost:3456** in your browser. The dashboard has seven panels:

| Panel | What it shows |
|-------|--------------|
| **Projects** | Active and recent Chris project status |
| **Agents** | Live polecat heartbeat and context usage |
| **Beads** | Current work queue and bead status |
| **Escalations** | Unresolved alerts needing attention |
| **Bugs** | Bug memory entries with warning status |
| **Convoys** | Active convoy groups with tracked issue counts |
| **Polecats** | Live polecat state across all rigs |

### Managing the dashboard

```bash
bash scripts/dashboard.sh status    # Show running state, PID, URL
bash scripts/dashboard.sh stop      # Stop the server
bash scripts/dashboard.sh restart   # Stop then start
bash scripts/dashboard.sh logs      # Tail the log file
bash scripts/dashboard.sh run       # Run in foreground (for debugging)
```

Logs and the PID file are stored in `$GT_ROOT/.runtime/` (default: `~/gt/.runtime/`).

---

## 4. Running the Pipeline

The Victory pipeline takes a project brief through PRD → spec → tasks → build cycles →
review gate → done. The `mol-victory-pipeline` formula orchestrates each stage.

### Step 1 — Create a bead for the project

```bash
bd create \
  --title="[pipeline] my-feature" \
  --type=epic \
  --description="Brief description of what to build" \
  --label "pipeline"
```

Note the bead ID that is printed (e.g., `vc-abc`).

### Step 2 — Pour the pipeline formula

```bash
gt formula run mol-victory-pipeline \
  --var brief="A clear description of the feature to build" \
  --var project="my-feature" \
  --var context=""
```

This runs the following stages in sequence:

| Stage | What happens |
|-------|-------------|
| `init` | Creates `projects/my-feature/` directory and tracking epic bead |
| `prd-draft` | Runs `mol-prd-draft` → writes `projects/my-feature/prd.md` |
| `spec-draft` | Runs `mol-spec-draft` → writes `projects/my-feature/spec.md` |
| `task-decompose` | Runs `mol-task-decompose` → creates wired child beads |
| `build-cycle` | Dispatches ready beads to polecats; loops until all tasks merge |
| `review-gate` | Three consultants (Quality, UX, SRE) review — PASS or FAIL |
| `done` | Closes epic, records artifacts |

### Step 3 — Monitor progress

```bash
bd list --label project:my-feature           # All beads for the project
bd list --label project:my-feature --status=open   # Remaining work
gt polecat list                               # Live polecat state
```

The dashboard at http://localhost:3456 also shows live progress across all panels.

### Step 4 — Sling individual beads (optional)

For small tasks that don't need the full pipeline, dispatch directly:

```bash
bd create --title="Fix the login bug" --type=bug --priority=1
gt sling <bead-id>
```

The polecat assigned picks up the bead, works through the formula checklist,
commits, and calls `gt done`. Refinery merges to `main` via the merge queue.

---

## 5. Model Routing

Victory selects the Claude model for each task using a 6-step resolution chain
implemented in `scripts/model_routing.py` and configured in `config/model-routing.toml`.

### Tiers

| Tier | Model | Use case |
|------|-------|----------|
| `fast` | `claude-haiku-4-5-20251001` | Triage, status checks, simple transforms |
| `medium` | `claude-sonnet-4-6` | Code generation, review, standard implementation |
| `deep` | `claude-opus-4-6` | Architecture, debugging, multi-file refactors |

### Resolution chain (highest priority first)

1. **Explicit override** — `--override MODEL` or `VICTORY_MODEL_OVERRIDE` env var
2. **P0 priority** — any P0 bead routes to `deep`
3. **Bead type** — `triage` → `fast`; `implementation` → `medium`; `architecture` → `deep`
4. **Complexity heuristic** — files changed > 5 OR deps > 3 → `deep`
5. **Role default** — `mayor` → `deep`; `polecat`/`witness` → `medium`; `refinery` → `fast`
6. **Sonnet fallback** — default `medium` tier

### Querying the resolver

```bash
# What model would a P1 implementation task use?
python3 scripts/model_routing.py --priority P1 --type implementation

# JSON output with tier and reason
python3 scripts/model_routing.py --role mayor --json

# Force a specific model for a session
VICTORY_MODEL_OVERRIDE=claude-opus-4-6 gt sling <bead-id>
```

---

## 6. Scheduled Orders

Victory runs three automated patrol jobs. These are defined in `orders/` and registered
with the Gas Town scheduler.

### `overnight-build` — Hourly dispatch

**Cron:** `0 * * * *` (top of every hour)

Scans for ready beads and dispatches up to 4 in parallel to available polecats.
This is the heartbeat of automated delivery — without it, the pipeline only advances
when a human calls `gt sling`.

**Gates:** skips if Dolt latency > 2 s, if the scheduler is paused, or if no polecats
are available.

### `pipeline-check` — Stuck stage patrol

**Cron:** `*/30 * * * *` (every 30 minutes)

Scans all active pipeline molecules for stalled stages:

- **Polecat stuck** (> 45 min in progress) → notifies the Witness, who nudges or restarts
- **Non-polecat stage stalled** (> 60 min, no activity) → notifies the Mayor
- **Dead build cycle** (2+ consecutive passes with zero merges) → HIGH escalation to Mayor

### `stale-project-detect` — Daily audit

**Cron:** `0 6 * * *` (06:00 UTC)

Identifies open pipeline epics with no bead activity:

- **Stale** (≥ 3 days, no activity) → included in daily report to Mayor
- **Dormant** (≥ 7 days, no activity) → HIGH escalation + report

When no stale projects exist, the order exits silently.

---

## 7. Troubleshooting

### Dolt not running

**Symptom:** `bd` commands hang, return "connection refused", or show empty results.

```bash
gt dolt status                   # Check health and latency
gt dolt start                    # Start if stopped
```

If Dolt is already running but misbehaving, collect diagnostics before restarting:

```bash
kill -QUIT $(cat ~/gt/.dolt-data/dolt.pid)   # Safe goroutine dump
gt dolt status 2>&1 | tee /tmp/dolt-hang.log
gt escalate -s HIGH "Dolt: <describe symptom>"
```

**Never** `rm -rf ~/.dolt-data/` — use `gt dolt cleanup` instead.

### Polecat stuck

**Symptom:** A polecat has been `in_progress` for more than 45 minutes with no commits.

```bash
gt polecat list          # List all polecats and their state
bd show <bead-id>        # Check the bead's notes for last known progress
```

The `pipeline-check` order notifies the Witness automatically. You can also notify
the Witness manually:

```bash
gt mail send victory/witness \
  -s "HELP: polecat stuck on <bead-id>" \
  -m "Polecat has been in_progress for >45 min with no commits. Please investigate."
```

### Review gate blocking

**Symptom:** The review gate keeps failing; pipeline is in a fix loop.

```bash
bd list --label project:my-feature,review-gate --status=open   # See open findings
```

After 3 gate/fix iterations, the pipeline escalates to the Mayor automatically.
To intervene manually, close a finding bead that is not applicable:

```bash
bd close <finding-bead-id> --reason="no-changes: finding is not applicable in this context"
```

To pause the pipeline and prevent further dispatch:

```bash
bd update <epic-bead-id> --label "on-hold"
```

### Dashboard not loading

```bash
bash scripts/dashboard.sh status    # Is it running?
bash scripts/dashboard.sh logs      # Check for startup errors
bash scripts/install.sh             # Re-run install if node_modules missing
```

The dashboard requires Dolt to be running for live data. Static structure will still
render, but panels will show empty state without a Dolt connection.

---

## 8. Extending Victory

### Adding a new agent

1. Create `agents/<name>.toml` following the existing agent definitions as a template.
2. Register the agent role in `config/model-routing.toml` under `[routing.roles]`
   if it needs a non-default model tier.
3. Add a prompt file to `prompts/<name>/` if the agent has a system prompt.
4. Re-run `bash scripts/smoke-test.sh` — the smoke test validates pack structure.

### Adding a new formula

1. Create `formulas/mol-<name>.toml` with `[[steps]]` entries.
2. Each step needs an `id`, `title`, `description`, and optionally `needs` for
   dependencies.
3. Declare input variables in `[vars]` at the bottom.
4. Test by running: `gt formula run mol-<name> --var <key>=<value>`

### Adding a new order (scheduled job)

1. Create `orders/<name>.toml` with `[order]`, `[schedule]`, and `[instructions]`
   sections. Use the existing orders as templates.
2. Register the cron schedule with the Gas Town scheduler:
   ```bash
   gt order register orders/<name>.toml
   ```
3. Test a manual run: `gt order run <name>`

### Adding a new dashboard panel

The dashboard is a Bun + Hono app in `dashboard/src/`. Routes follow the pattern
in `dashboard/src/routes/`. Add a new route file and register it in the router.
Each panel polls a Dolt query and pushes updates via SSE.

---

## Quick Reference

```bash
# Install
bash scripts/install.sh

# Smoke test
bash scripts/smoke-test.sh

# Dashboard
bash scripts/dashboard.sh start
open http://localhost:3456

# Run a full pipeline
gt formula run mol-victory-pipeline --var brief="..." --var project="my-feature"

# Dispatch a single bead
gt sling <bead-id>

# Check rig health
gt dolt status
gt polecat list
bd list --status=open

# Model routing
python3 scripts/model_routing.py --role polecat --json
```
