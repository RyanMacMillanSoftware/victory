# Victory

Victory is a Gas Town (GT) rig pack — a deployable configuration bundle for autonomous code delivery CI/CD operations.

## What's Included

- **Agents** — AI agent definitions for planner, researcher, quality consultant, UX consultant, and SRE consultant
- **Formulas** — Workflow templates for the full delivery pipeline (PRD → spec → build → review)
- **Dashboard** — Real-time Bun + HTMX + SSE web UI for monitoring bead/agent state
- **Orders** — Scheduled patrol jobs (pipeline-check, overnight-build, stale-project-detect)

## Quick Start

1. Install the pack into a GT rig: `bash scripts/install.sh`
2. Start the dashboard: `bash scripts/dashboard.sh`
3. Run the smoke test: `bash scripts/smoke-test.sh`

## Pipeline

The mol-victory-pipeline formula orchestrates the full delivery lifecycle: brief → PRD → spec → tasks → build cycles → review gate → done.

Refer to `formulas/` for individual workflow templates and `agents/` for agent prompt definitions.
