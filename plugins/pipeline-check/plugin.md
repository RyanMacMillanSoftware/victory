+++
name = "victory-pipeline-check"
description = "Detect stuck polecats and stalled pipeline stages in the Victory rig; notify Witness or Mayor"
parallel = false

[gate]
type = "cron"
cron = "*/30 * * * *"
timezone = "UTC"

[vars]
rig = "victory"
witness = "victory/witness"
polecat_stuck_minutes = "45"
stage_stall_minutes = "60"
escalation_threshold = "2"
dead_cycle_threshold = "2"
+++

# Victory Pipeline Check

You are executing the `pipeline-check` order for the Victory rig. This patrol
detects stuck polecats and stalled pipeline stages, then notifies the right agent.

Work from your dog directory.

## Your Mission

Scan all active Victory pipeline molecules for stalled stages and stuck polecats.
Notify the Witness for stuck polecats; notify the Mayor for stalled non-polecat stages;
escalate to Mayor when a build cycle is dead.

## Steps (execute in order)

### Step 1: Verify Dolt health

```bash
gt dolt status
```

If Dolt latency > 2000ms or server is down, abort and escalate:

```bash
gt escalate -s HIGH "pipeline-check: Dolt unhealthy — skipping patrol"
gt dog done
```

Do NOT restart Dolt yourself.

### Step 2: List active pipeline molecules

```bash
bd mol list --formula mol-victory-pipeline --status=open --json
bd mol list --formula mol-build-cycle --status=open --json
```

Collect all active molecule IDs and their current step beads.

### Step 3: Check each molecule for stuck/stalled stages

For each active molecule:

```bash
bd mol status <mol-id>
bd show <current-step-bead-id>
```

Compare the step's `updated_at` timestamp against the current time:

- If the step is assigned to a polecat and age > 45 minutes → **stuck polecat**
- If the step is a non-polecat stage and age > 60 minutes with no bead updates → **stalled stage**

**For a stuck polecat:**
```bash
gt mail send victory/witness --stdin <<'BODY'
PIPELINE_CHECK: polecat <name> stuck on <bead-id> for <duration>.
Stage: <stage-name>. Please investigate.
BODY
```

**For a stalled non-polecat stage:**
```bash
gt mail send mayor/ --stdin <<'BODY'
PIPELINE_CHECK: stage <stage-name> on project <project> has been open for <duration>
with no activity. Gate may be stuck. Please review.
BODY
```

### Step 4: Check for dead build cycles

For each active `mol-build-cycle` molecule, read the cycle metadata:

```bash
bd show <mol-bead-id>
```

If `consecutive_empty_dispatches` in the bead notes >= 2, escalate:

```bash
gt escalate -s HIGH "Build cycle dead: project <project> — 2+ consecutive dispatch passes with zero merges. Please intervene."
```

### Step 5: Report and complete

Log a summary of what was found:

```
pipeline-check: N molecules scanned, N stuck polecats, N stalled stages, N dead cycles
```

Send DOG_DONE mail to deacon/ with your summary:

```bash
gt mail send deacon/ -s "DOG_DONE victory-pipeline-check" -m "<your summary>"
```

Then call:

```bash
gt dog done
```

This clears your work assignment and terminates your session automatically.
