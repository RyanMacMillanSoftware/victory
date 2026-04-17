# Victory — AGENTS.md

Victory is a Gas Town rig pack: a deployable configuration bundle for autonomous
code delivery CI/CD operations. When installed into a GT rig, it provides the
agents, formulas, scripts, and configuration needed to run the full Victory
pipeline — from initial project brief to merged, production-ready code.

## What Victory provides

### Agents (`agents/`)

Five specialized agents used in the Victory pipeline:

| Agent | Role |
|---|---|
| `planner` | City-scoped orchestration agent. Drives projects through all pipeline stages (PRD → Spec → Tasks → Build → Review). Owns the full lifecycle from first bead to merge queue. |
| `researcher` | General-purpose research agent. Gathers codebase, technology, and documentation findings for other pipeline agents. |
| `quality-consultant` | Review Gate consultant. Evaluates implementation against spec for correctness, code quality, and completeness. |
| `ux-consultant` | Review Gate consultant. Evaluates implementation for UX alignment, accessibility, and interaction quality. |
| `sre-consultant` | Review Gate consultant. Evaluates implementation for production reliability, operability, and safety. |

### Formulas (`formulas/`)

Seven workflow templates (`.toml`) that define step-by-step checklists for pipeline stages:

| Formula | Purpose |
|---|---|
| `mol-victory-pipeline` | Full pipeline from project brief to shipped feature |
| `mol-prd-draft` | PRD (Product Requirements Document) drafting |
| `mol-spec-draft` | Technical specification drafting |
| `mol-task-decompose` | Task decomposition into bead-sized units of work |
| `mol-build-cycle` | Build, test, lint, and verification cycle |
| `mol-review-gate` | Multi-consultant review (quality, UX, SRE) — coordinator role, no code commits |
| `mol-onboard-repo` | Repository onboarding for new projects entering the pipeline |

### Dashboard (`dashboard/`)

Real-time web dashboard built with Bun + Hono + HTMX + SSE.

- Routes: projects, agents, beads, escalations, bugs
- Polls Dolt (port 3307) for live bead and agent state
- SSE for live updates without page reload
- Start with: `bash scripts/dashboard.sh`

### Scripts (`scripts/`)

| Script | Purpose |
|---|---|
| `install.sh` | Pack installation: dependencies, migrations, preflight checks. Run after clone or update. Flags: `--dry-run`, `--skip-migrations` |
| `dashboard.sh` | Start the dashboard server |
| `smoke-test.sh` | End-to-end validation (31 checks). Does not require a running Dolt server. `bash scripts/smoke-test.sh` |
| `bug-warn-inject.sh` | Injects bug memory warnings at sling time |
| `migrate.sh` | Dolt schema migrations |
| `model_routing.py` / `model-routing.sh` | Model routing utilities |
| `test-consultant-review.sh` | Test harness for consultant review flow |
| `test-model-routing.sh` | Test harness for model routing |

### Configuration (`config/`)

| File | Purpose |
|---|---|
| `defaults.toml` | Base settings: timeouts, commit conventions, quality gate slots, RTK config |
| `model-routing.toml` | Per-agent model assignments and routing rules |
| `safety-rails.toml` | Guardrails applied to all agents in the rig |
| `hooks.json` | PreToolUse hook config (RTK rewrite integration) |

### Prompts (`prompts/`)

- `polecat/brief.md` — System prompt for dispatched polecat workers
- `onboarder/` — Onboarder agent prompts
- `planner/` — Planner agent prompts
- `consultants/` — Consultant review prompts

## Rig identity

| Property | Value |
|---|---|
| Rig name | `victory` |
| Bead prefix | `vc` |
| Default branch | `main` |
| Polecat slots | `rust`, `go`, `node` |
| Merge strategy | bisecting (batch size 4) |
| Dolt database | `beads_victory` |

## Quality gates

Victory does not define project-specific build/test/lint commands — those are
configured per-project in each onboarded repo's AGENTS.md or rig settings.
The gate slots (`setup_command`, `build_command`, `test_command`, `lint_command`,
`typecheck_command`) are defined in `config/defaults.toml`.

For Victory's own validation, run:
```bash
bash scripts/smoke-test.sh   # 31 checks, all must pass
```

## RTK integration

Victory uses RTK (Refinery Token Kit) to reduce context consumption in polecat
sessions. The hook is configured in `config/hooks.json` and merged into
`polecats/.claude/settings.json` at install time.

- Min version: `0.23.0`
- Hook script: `~/.claude/hooks/rtk-rewrite.sh`
- Enable globally: `rtk init -g`

## Installation

```bash
bash scripts/install.sh         # Full install (requires Dolt running)
bash scripts/install.sh --dry-run          # Preview what would be done
bash scripts/install.sh --skip-migrations  # Skip Dolt schema setup
```

## Core rule

Work is done when `bash scripts/smoke-test.sh` passes all 31 checks and the
working tree is clean with at least one commit ahead of `origin/main`.
