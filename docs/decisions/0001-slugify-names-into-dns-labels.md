# 1. Slugify names into DNS labels

**Status**: Accepted (2026-07-15)

## Context
Workspace/branch names contain `_`, `.`, spaces — not valid in a DNS label. `alloc_ip` needs a stable, collision-resistant label for `hosts.d/<label>`.

## Decision
`sanitize_name` (`lib/dev-ip-lib.sh:7-12`): lowercase, each run of non-`[a-z0-9]` collapses to a single `-`, trim leading/trailing `-`, truncate to 63 chars.

## Alternatives considered
- Literal-drop (`/`→`-`, then drop other non-`[a-z0-9-]` chars) — merges words across separators (`my_branch`→`mybranch`), collision-prone.

## Consequences
`my_branch` → `my-branch`, reads as two words. Matches the shipped `sanitize_name`; any future change to the regex is a breaking change to existing `hosts.d` filenames.
