# gate=manual Daemon Dispatch Bug (hq-suin)

**Status:** Upstream PR open — workaround active

## Summary

The gastown daemon's `dispatchPlugins()` had no explicit guard for
`gate=manual` plugins. It silently skipped non-cooldown gate types, but
this relied on the cooldown check being reached. A misconfigured
plugin.md using the wrong TOML field name (`cooldown = "4h"` instead of
`duration = "4h"`) made `p.Gate.Duration` empty, bypassing cooldown and
causing infinite re-dispatch loops.

## Root Causes

1. **Wrong TOML field** — `cooldown = "4h"` is silently ignored by the
   BurntSushi TOML parser. The correct field is `duration = "4h"` (maps
   to `Gate.Duration` in `internal/plugin/types.go`).

2. **Missing explicit gate=manual guard** — `dispatchPlugins()` had no
   `GateManual` check; the gate type was only implicitly skipped.

## Fix

Upstream PR: https://github.com/gastownhall/gastown/pull/3764

Adds to `internal/daemon/handler.go` (`dispatchPlugins`):

```go
if p.Gate != nil && p.Gate.Type == plugin.GateManual {
    d.logger.Printf("Handler: skipping plugin %s (gate=manual, requires explicit trigger)", p.Name)
    continue
}
```

## Workaround (active until PR merged + daemon restarted)

`/Users/ryan/gt/plugins/mol-dog-reaper/plugin.md` — `[gate] type = "manual"`.

Restore to `type = "cooldown"` with `duration = "4h"` after the daemon
is updated.
