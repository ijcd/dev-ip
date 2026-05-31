# 6. Kernel advisory lock (perl flock) for concurrent alloc

**Status**: Accepted (2026-07-29)

## Context
ADR-0002's `mkdir` lock is atomic but has no crash recovery: a run interrupted mid-allocation (Ctrl-C, kill, crash) leaves the `.lock` directory behind, and every later allocation then fails with "could not acquire lock" until it is removed by hand. This happened in real use.

## Decision
Hold an exclusive kernel advisory lock via `perl`'s `flock` (macOS has no `flock(1)`) on `hosts.d/.lock`. `_with_lock` opens the file on fd 9, a short `perl` invocation `flock()`s that inherited fd and exits, and the lock stays held by the shell's fd 9 for the in-process critical section — released by `exec 9>&-` or by the kernel when the shell dies.

## Alternatives considered
- Trap `INT`/`TERM`/`EXIT` to release — cannot catch `SIGKILL`, OOM-kill, or crash; incomplete.
- `mkdir` + PID file + `kill -0` staleness — steal race (deleting a freshly-acquired valid lock) and PID reuse; hand-rolled concurrency risk.
- `shlock(1)` (BSD, present) — does PID-based staleness for you but still has the PID-reuse edge; `flock` has none.

## Consequences
Supersedes ADR-0002's mechanism. A stale lock is now impossible in any death mode — the kernel releases on fd close. The `.lock` file is a permanent, content-less lock target (never needs cleanup). Adds `perl` as a runtime dependency (base macOS). The fast path (existing mapping) stays lock-free.
