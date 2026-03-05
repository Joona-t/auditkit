# Auditkit v2 — Research

## Problem

Auditkit v1 handles basic hash-tree diffing and free-text claim verification. The user identified five gaps:

1. **No plan.md integration** — plans use structured TODO IDs (`**2.7**`) but verify-claims only parses `- ` prefixed lines. No 1:1 mapping between plan items and verification results.
2. **Weak evidence anchoring** — PASS verdicts sometimes lack file:line evidence. UNKNOWN verdicts don't show "closest hits" to speed manual review.
3. **No artifact/zip auditing** — after build-zips.sh, no way to compare zip contents against an allowlist or the source tree.
4. **No gate checklist output** — scripts don't emit a structured PASS/FAIL gate summary.
5. **No composability** — no `--json` or `--quiet` on shell scripts; can't chain into CI.

## Existing Codebase Analysis

### Plan.md format (from lovespark-notes/plan.md)

```
- [ ] **1.1** `manifest.json` — add "identity" to permissions
- [ ] **2.7** Implement `fullSync()` — pull-merge-push
```

Pattern: `- [ ] **ID** description` or `- [x] **ID** description`
IDs are dot-separated: `1.1`, `2.7`, `3.4`
Some lines have backtick-quoted file/function names — these are the grep targets.

Also seen: `DECISION #5:` style headers in plan files. These should also be parseable.

### verify-claims.py current parse

Only parses `- ` prefix. Returns `(verdict, evidence)` where evidence is max 3 grep hits.
Needs: structured claim ID field, richer evidence, "closest hits" for UNKNOWN.

### build-zips.sh

Outputs to `lovespark zips/chrome zips/` and `firefox zips/`. Zips exclude `.git, .gitignore, generate_icons.py, .DS_Store, .claude, __pycache__`. No manifest of expected contents.

### Shell script conventions (from existing scripts/)

- `#!/bin/bash`, `set -e`
- `"${1:?Usage: ...}"` for required args
- UPPER_CASE constants
- No colors, plain text output
- Python called inline for JSON parsing
- No `--json` or `--quiet` flags on any existing script

### What rg/grep can do for git-diff mode

`git diff --name-only HEAD~1` gives changed files. `git diff HEAD~1 -- file` gives hunks.
For claim verification against a diff: instead of grepping the whole tree, grep only in changed lines. Much more precise for "did this claim correspond to an actual change."

## Design Decisions

### D1: Claim format contract

Two parseable formats:
1. **Plan TODO**: `- [ ] **ID** description` → extracts ID + description
2. **Free-text claim**: `- description` → no ID, auto-numbered

`audit-plan.sh` uses format 1 (reads plan.md directly). `verify-claims.py` supports both.

### D2: Evidence anchoring

Every verdict must include evidence:
- **PASS**: at least one `file:line: snippet` (up to 3)
- **FAIL**: the contradicting evidence (e.g., "file still exists")
- **UNKNOWN**: "closest hits" — top 3 grep matches sorted by token overlap, even if below threshold

This means `verify_claim()` must always collect and return grep hits, even when match_count < 2.

### D3: Git-diff mode

New flag `--git-diff [REF]` on verify-claims.py:
- Runs `git diff --name-only REF` to get changed files
- Runs `git diff REF -- file` for each to get changed lines
- Verification searches only within changed content
- Default REF: `HEAD~1`

### D4: Artifact allowlist

`audit-zip.sh` takes:
- A zip file (or unpacked dir)
- An allowlist file (one glob pattern per line)
- Reports: unexpected files, missing required files, size anomalies (file > 500KB)

Allowlist format:
```
# Required
manifest.json
popup.html
popup.js
# Optional (glob)
icons/*.png
lib/*.js
```

Lines starting with `#` are comments. Lines starting with `!` are required (must exist).

Simpler: all lines are "expected." A separate `# Required` section marks mandatory files. Or just: lines prefixed with `!` = required, others = allowed-optional.

Final: `!manifest.json` = required. `icons/*.png` = allowed. Anything not matching any pattern = unexpected.

### D5: Gate checklist output

All scripts gain a `--gates` flag (or just always emit gates at the end).
Format:
```
GATES:
  PASS: all claims verified
  FAIL: 2 files unexpected in zip
  PASS: no size anomalies
```

Simple structured output that can be grepped.

### D6: Composability flags

Shell scripts: `--json` pipes output as JSON to stdout. `--quiet` suppresses human-readable output (exit code only).
Python: already has `--json`. Add `--quiet`.

Implementation: shell scripts that need `--json` will call a small Python helper or use inline `python3 -c` for JSON formatting (matching existing convention in build-zips.sh and audit-permissions.sh).

Actually simpler: `--json` on shell scripts outputs one-JSON-object-per-line (JSONL). Python scripts output a single JSON array/object. This avoids needing jq in bash.

### D7: regression-scenarios.md

A template + convention, not executable code. Documents named scenarios with:
- Scenario name
- What to look for in code (functions, message types)
- Manual test steps
- Automated check (grep pattern to run)

`scenario-runner.sh` is a stub that reads the file and runs the grep patterns, reporting FOUND/NOT_FOUND per scenario.

## New File Structure

```
auditkit/
├── (existing files)
├── audit-plan.sh              (~40 lines) — NEW
├── audit-zip.sh               (~60 lines) — NEW
├── snapshot-wrap.sh            (~30 lines) — NEW
├── scenario-runner.sh          (~35 lines) — NEW
├── verify-claims.py           (modify: +structured IDs, +--git-diff, +evidence anchoring, +--quiet)
├── diff-hash-trees.sh         (modify: +--json, +--quiet)
├── hash-tree.sh               (modify: +--json)
├── templates/
│   ├── notes-update.md        (existing)
│   ├── allowlist.txt           — NEW template
│   └── regression-scenarios.md — NEW template
└── _selftest/
    ├── (existing fixtures)
    ├── plan.md                 — NEW test fixture
    └── allowlist.txt           — NEW test fixture
```

## Implementation Order

1. Update verify-claims.py (structured IDs, evidence anchoring, --git-diff, --quiet)
2. audit-plan.sh
3. snapshot-wrap.sh
4. audit-zip.sh + templates/allowlist.txt
5. scenario-runner.sh + templates/regression-scenarios.md
6. Add --json/--quiet to hash-tree.sh and diff-hash-trees.sh
7. New selftest fixtures (plan.md, allowlist.txt)
8. Update run-selftest.sh with new assertions
9. Update README.md
