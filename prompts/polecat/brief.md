# Polecat Assignment Brief

Generated at sling time. Contains the assignment context and any known bug
patterns in the files this task will touch.

---

## Assignment

See hooked bead for full details (`bd show {{issue}}`).

---

## Bug Memory Warnings

<!-- Bug warnings are appended here at sling time by scripts/bug-warn-inject.sh.
     If no warnings appear below, no known issues matched this task's file patterns.
     
     To generate and append warnings manually:
       ./scripts/bug-warn-inject.sh <file-path> [<file-path>...] >> brief.md
     
     To view all active warnings (no pattern filter):
       ./scripts/bug-warn-inject.sh
-->

*(No active bug warnings matched this assignment.)*

---

## How Bug Warnings Are Injected

At sling time, the Victory build cycle:

1. Reads the bead's title and description to extract mentioned file paths
2. Calls `scripts/bug-warn-inject.sh <extracted-paths>` to query `bug_memory`
3. If warnings are returned, they replace the placeholder above
4. The completed brief is passed as `--message` to `gt sling`

The polecat sees warnings in their context via `gt prime --hook` at session start.

### Pattern Matching

The `bug_memory` table stores `file_pattern` as glob-style patterns (e.g., `scripts/*.sh`,
`config/*.toml`, `*.ts`). The injection script checks whether any given file path would
be matched by a stored pattern using SQL `LIKE`:

```sql
WHERE 'scripts/migrate.sh' LIKE REPLACE(file_pattern, '*', '%')
```

Up to 5 matching warnings are surfaced, ordered by `occurrence_count` descending
(most frequently seen bugs first).

### Adding to Bug Memory

When you fix a recurring bug, document it for future polecats:

```sql
INSERT INTO bug_memory (id, code_area, file_pattern, bug_title, warning_text,
    root_cause, fix_summary, fix_bead, occurrence_count, status)
VALUES (
    'bm-<short-id>',
    'scripts',
    'scripts/*.sh',
    'Short description of the bug',
    'What to watch out for when touching this area...',
    'Root cause analysis...',
    'How the fix was applied...',
    'hq-<fix-bead-id>',
    1,
    'active'
);
```

Or use the migration script after adding entries to the schema:
```bash
./scripts/migrate.sh
```
