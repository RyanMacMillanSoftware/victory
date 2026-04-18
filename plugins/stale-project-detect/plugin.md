+++
name = "victory-stale-project-detect"
description = "Detect stale Victory projects (no pipeline activity in N days) and report dormant/stale projects to Mayor"
parallel = false

[gate]
type = "cron"
cron = "0 6 * * *"
timezone = "UTC"

[vars]
rig = "victory"
stale_days = "3"
dormant_days = "7"
min_open_beads = "1"
report_recipient = "mayor/"
+++

# Victory Stale Project Detect

You are executing the `stale-project-detect` order for the Victory rig. This audit
identifies open pipeline epics with no bead activity and reports them to the Mayor.

Work from your dog directory.

## Your Mission

Find all open Victory pipeline epics that have had no activity for 3+ days.
Report stale projects to the Mayor; immediately escalate dormant projects (7+ days).
If no stale projects exist, exit silently.

## Steps (execute in order)

### Step 1: Verify Dolt health

```bash
gt dolt status
```

If Dolt is unhealthy, abort and escalate:

```bash
gt escalate -s HIGH "stale-project-detect: Dolt unhealthy — skipping audit"
gt dog done
```

### Step 2: Find all open pipeline epics

```bash
bd list --label pipeline --status=open --rig victory --json
bd list --label pipeline --status=in_progress --rig victory --json
```

Collect all epic bead IDs.

### Step 3: Classify each epic

For each epic bead:

1. Skip if labeled with `paused`, `deferred`, or `on-hold`.

2. Count open child beads:
   ```bash
   bd list --parent <epic-id> --status=open --count
   ```
   If count < 1, skip (project is complete or quiescent).

3. Find last activity:
   ```bash
   bd show <epic-id>
   bd list --parent <epic-id> --sort=updated --limit=1 --json
   ```

4. Calculate days since last activity.

5. Classify:
   - days >= 7 → **DORMANT**
   - days >= 3 → **STALE**
   - else → **ACTIVE** (skip)

### Step 4: Exit silently if nothing to report

If no STALE or DORMANT projects are found, skip the remaining steps and go directly
to Step 6 (report and complete). Do NOT send a report to the Mayor.

### Step 5: Escalate dormant projects

For each DORMANT project (>= 7 days):

```bash
gt escalate -s HIGH "Project <project_slug> (<epic-id>) has had no activity for <N> days. Last stage: <stage>. Please decide: resume, defer, or close."
```

### Step 6: Send daily report (if stale/dormant projects found)

If any STALE or DORMANT projects were found, compose and send the report:

```bash
gt mail send mayor/ --stdin <<'BODY'
## Stale Project Report — <YYYY-MM-DD>

### Dormant (>= 7 days, no activity)
<list dormant projects: slug, epic-id, days since activity, open bead count, current stage>

### Stale (>= 3 days, no activity)
<list stale projects: slug, epic-id, days since activity, open bead count, current stage>

### Recommended actions
- RESUME: re-dispatch the current stage bead to an available polecat
- DEFER:  bd update <epic-id> --status=deferred
- CLOSE:  bd close <epic-id> --reason='stale: no longer relevant'
BODY
```

Use subject: `STALE_PROJECTS: <N> projects need attention (<YYYY-MM-DD>)`

### Step 7: Report and complete

Log a summary:

```
stale-project-detect: N epics scanned, N stale, N dormant, report sent to Mayor
```

Send DOG_DONE mail to deacon/ with your summary:

```bash
gt mail send deacon/ -s "DOG_DONE victory-stale-project-detect" -m "<your summary>"
```

Then call:

```bash
gt dog done
```

This clears your work assignment and terminates your session automatically.
