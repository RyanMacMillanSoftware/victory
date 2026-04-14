# Consultant Review Protocol

The consultant review is the final quality gate in the Victory pipeline. It runs
after the Build Cycle and before delivery acceptance. Three domain consultants
review project artifacts, file findings as beads, and block the gate for any
P0 or P1 issues they find.

## Consultants

| Agent | Domain | Focus |
|-------|--------|-------|
| `ux-consultant` | User Experience | UX anti-patterns (Impeccable 24), interaction flows, accessibility, clarity |
| `sre-consultant` | Site Reliability | Observability, failure modes, deployment safety, operational risk |
| `quality-consultant` | Code Quality | Correctness, test coverage, security, maintainability, conventions |

Each consultant is an independent agent with a dedicated system prompt. They run
in parallel during full-intensity reviews.

## Tiered Intensity

Review depth depends on what is being reviewed.

### Full Review

Applies to: **PRDs, Specs, MRs, and deliverable artifacts**

All relevant consultants review the artifact independently. Each files findings
from their domain perspective. Appropriate when the artifact is a primary
deliverable that will affect users, operators, or codebase quality.

| Artifact Type | Consultants |
|--------------|-------------|
| PRD (`prd`) | UX, Quality |
| Spec (`spec`) | SRE, Quality |
| MR (`mr`) | UX, SRE, Quality |
| Deliverable artifact (`artifact`) | UX, SRE, Quality |

### Light Review

Applies to: **Bead descriptions and status notes** (`bead`)

Quality consultant only. Time-boxed to 15 minutes. Focused scan for obvious
errors: scope drift, missing context, contradictory requirements. Only P0/P1
findings are filed — P2/P3 threshold is intentionally higher for beads.

## Review Bead Creation Flow

Each consultant creates finding beads using `bd create`. Every finding bead must
include:

1. **Title**: concise description of the finding
2. **Type**: `bug` for defects; `task` for improvements
3. **Priority**: P0–P3 (see severity table below)
4. **Description**: location, observed vs. expected, impact, suggested fix

### Finding Bead Template

```bash
bd create --type=bug --priority=<0|1|2|3> \
  --title="<ConsultantType>: <concise finding title>" \
  --description="Found during <consultant-type> review of <artifact>.

Location: <file:line, section, or component>

Observed:
<what the consultant saw>

Expected:
<what should be there instead>

Impact:
<why this matters — user impact, operational risk, or quality degradation>

Suggested fix:
<concrete recommendation if known>"
```

## Severity Levels

| Priority | Label | Description | Gate Impact |
|----------|-------|-------------|-------------|
| P0 | Critical | Security vulnerability, data loss, broken pipeline | **Blocks gate** |
| P1 | High | Functional defect, user-facing breakage, operational risk | **Blocks gate** |
| P2 | Medium | Code quality, UX friction, missing observability | Non-blocking |
| P3 | Low | Improvement opportunity, style, nice-to-have | Non-blocking |

P0 findings must also trigger an escalation:

```bash
gt escalate "P0 finding: <title>" -s HIGH -m "Gate: <gate-bead-id>
Project: <project>
Finding: <bead-id>
Details: <brief description>"
```

## Gate Mechanism

The gate bead represents the Review Gate pipeline stage. It cannot close while
it has open blocking dependencies.

### Adding a Blocker

When a consultant files a P0 or P1 finding, they MUST add a blocking dependency
on the gate bead immediately after creating the finding bead:

```bash
# Create the finding bead first
FINDING=$(bd create --type=bug --priority=1 \
  --title="SRE: Missing health check endpoint" \
  --description="..." | grep "^id:" | awk '{print $2}')

# Then block the gate
bd dep add <gate-bead-id> $FINDING
```

The `bd dep add <blocked> <blocker>` call means:
> The gate bead (`<blocked>`) depends on the finding bead (`<blocker>`) being
> resolved before it can close.

### Verifying Gate Blockers

```bash
bd dep list <gate-bead-id> --direction=depends_on
```

This lists all beads that must be closed before the gate can close.

### Resolving Blockers

When a polecat fixes a P0/P1 finding:
1. The fix is implemented and merged via `gt done`
2. The finding bead is closed: `bd close <finding-bead-id>`
3. The blocking dep is automatically satisfied

Once all blocking deps are closed, the gate coordinator re-assesses and closes
the gate bead.

## Review Workflow

The full review flow is orchestrated by the `mol-review-gate` formula. When
the Review Gate stage is reached in a project pipeline:

1. **Classify intensity** — determine full or light based on `artifact_type`
2. **Dispatch consultants** — create assignment beads for each consultant
3. **Consultants review in parallel** — each files findings and sets blockers
4. **Collect findings** — coordinator tallies all P0/P1/P2/P3 beads
5. **Apply gate mechanism** — ensure all P0/P1 finding beads block the gate
6. **Assess gate** — check all blockers; escalate P0 findings
7. **Close or hold** — close gate on PASS; leave open with blockers on BLOCK

## Gate Pass Criteria

The Review Gate passes when:

- No P0 findings exist, **AND**
- No P1 findings exist, **OR** all P1 findings have been closed (fixed)

P2 and P3 findings do not block the gate. They remain open as tracked work
items for future cleanup.

## Attaching to a Pipeline

The planner attaches `mol-review-gate` to the Review Gate bead:

```bash
bd mol attach <gate-bead-id> \
  --formula=mol-review-gate \
  --var artifact=<path-or-bead-id> \
  --var artifact_type=mr \
  --var gate_bead=<gate-bead-id> \
  --var project=<project-slug>
```

This is done automatically by the `mol-victory-pipeline` formula when a new
project pipeline is created.
