# Auditkit v2 — Plan (revised)

**Do not implement yet.**

## Summary

Two tracks: (A) harden v1 tools based on review, (B) add new tools. Track A first — it fixes the foundation before building on it.

---

## TODO Checklist

### Phase 1: Harden hash-tree.sh

- [ ] **1.1** SHA command fallback — detect `shasum -a 256` vs `sha256sum`, pick whichever exists
- [ ] **1.2** Extra excludes via env var — `AUDITKIT_EXCLUDE="coverage .next .turbo"` appended to the default exclude list. Parse space-separated dir names into `-not -path` args
- [ ] **1.3** Add `--json` flag — output `[{"hash":"...","path":"..."},...]`
- [ ] **1.4** Add `--quiet` flag — suppress output, exit 0 if dir has files, exit 1 if empty

### Phase 2: Harden diff-hash-trees.sh

- [ ] **2.1** Replace grep-per-file loop with single-pass awk approach:
  - Read FILE_A into awk, build path→hash map
  - Read FILE_B into awk, build path→hash map
  - Compare in O(n): emit ADDED/REMOVED/CHANGED
  - Use a single awk script invocation, pipe both files with a separator marker
- [ ] **2.2** Add `--json` flag — output `{"added":[...],"removed":[...],"changed":[...]}`
- [ ] **2.3** Add `--quiet` flag — exit 0 if no changes, exit 1 if changes

### Phase 3: Harden unpack-zip-clean.sh

- [ ] **3.1** Enable `dotglob` + `nullglob` before the flattening mv to catch dotfiles
- [ ] **3.2** Collision detection — before mv, check if any source filename already exists in OUT_DIR. If collision, fail with explicit error listing the conflicting filenames
- [ ] **3.3** Restore shell options (`shopt -u dotglob`) after mv

### Phase 4: Harden verify-claims.py

- [ ] **4.1** Structured claim format (alongside existing freeform):
  - `- [TODO 2.7] add file shared/sync-google.js` → parsed as ID=2.7, action=add, target=shared/sync-google.js
  - `- remove file popup/legacy.js` → parsed as action=remove, target=popup/legacy.js
  - `- must contain "sync.tombstone" in background.js` → parsed as action=contains, pattern=sync.tombstone, file=background.js
  - Freeform `- some claim text` still works as before (auto-numbered, heuristic matching)
- [ ] **4.2** Tighter token extraction:
  - Only treat tokens as file patterns if they have a recognized extension (`.js`, `.py`, `.json`, `.html`, `.css`, `.ts`, `.sh`, `.md`, `.txt`) or contain `/`
  - Filter out common English words (stopwords > 3 chars: "with", "from", "that", "this", "into", etc.)
- [ ] **4.3** Strict evidence contract:
  - PASS: must include at least one anchored hit (`path:line:snippet`) or a file existence proof (`file X found at path`)
  - FAIL: must include contradiction evidence
  - UNKNOWN: must include "closest hits" — top 3 grep matches sorted by relevance, even if below threshold
- [ ] **4.4** Add `--git-diff [REF]` flag:
  - Run `git diff --name-only REF` for changed files list
  - Run `git diff REF` for changed content
  - Search only within diff output, not full tree
  - Default REF: `HEAD~1`
- [ ] **4.5** Add `--quiet` flag — no output, exit 0 = all PASS, exit 1 = any FAIL, exit 2 = any UNKNOWN (no FAIL)
- [ ] **4.6** Structured ID parsing from plan.md format — detect `**ID**` in claims, store as `claim_id` field in output
- [ ] **4.7** Update `--json` to include `claim_id`, and evidence as `{"file":"...","line":N,"snippet":"..."}` objects

### Phase 5: audit-plan.sh

- [ ] **5.1** Read plan.md, extract unchecked TODO lines (`- [ ] **ID** description`)
- [ ] **5.2** Skip checked lines (`- [x] **ID** ...`) — optionally report as SKIP
- [ ] **5.3** Convert extracted TODOs into structured claims, pipe to verify-claims.py
- [ ] **5.4** Output per-ID verdict:
  ```
  TODO 1.1 — PASS (manifest.json:3: "identity")
  TODO 2.7 — UNKNOWN (no matching diff)
  ```
- [ ] **5.5** Pass-through flags: `--json`, `--quiet`, `--git-diff [REF]`

### Phase 6: snapshot-wrap.sh

- [ ] **6.1** Takes a directory arg, runs hash-tree (before snapshot), saves to temp
- [ ] **6.2** Prints "Make your changes, then press Enter" and waits
- [ ] **6.3** On Enter: hash-tree again (after), run diff-hash-trees, print results
- [ ] **6.4** Optional `--claims FILE` — also runs verify-claims against the dir
- [ ] **6.5** Optional `--plan FILE` — also runs audit-plan against the dir
- [ ] **6.6** Saves all artifacts to `/tmp/auditkit-session-TIMESTAMP/`

### Phase 7: audit-zip.sh

- [ ] **7.1** Takes zip file + allowlist file as args
- [ ] **7.2** Unpack via unpack-zip-clean.sh into temp dir
- [ ] **7.3** Allowlist format:
  - `!manifest.json` = required (must exist)
  - `icons/*.png` = allowed (may exist)
  - `# comment` = ignored
- [ ] **7.4** Report three categories:
  - UNEXPECTED: files not matching any allowlist pattern
  - MISSING: required files (`!` prefix) not found
  - SIZE_ANOMALY: any file > 500KB
- [ ] **7.5** Optional `--source-dir` — hash both source and zip, diff them
- [ ] **7.6** `--json` and `--quiet` flags
- [ ] **7.7** Create `templates/allowlist.txt` with common extension file patterns

### Phase 8: audit-run.sh (single wrapper)

- [ ] **8.1** Orchestrator script — runs the full audit pipeline in one command
- [ ] **8.2** Inputs: `--dir DIR` (required), plus optional `--plan FILE`, `--claims FILE`, `--zip FILE`, `--allowlist FILE`, `--before-hash FILE`
- [ ] **8.3** Steps:
  1. Hash-tree the dir (or use `--before-hash` for pre-existing snapshot)
  2. Diff against before-hash if provided
  3. Run verify-claims if `--claims` given
  4. Run audit-plan if `--plan` given
  5. Run audit-zip if `--zip` + `--allowlist` given
- [ ] **8.4** Write `AUDIT_REPORT.md` — human-readable, all sections combined
- [ ] **8.5** Write `AUDIT_REPORT.json` — machine-readable, all results combined
- [ ] **8.6** Gate summary at end of both files:
  ```
  GATES:
    PASS: all claims verified
    FAIL: 2 unexpected files in zip
    PASS: no size anomalies
  ```
- [ ] **8.7** Exit code: 0 = all gates pass, 1 = any gate fails

### Phase 9: scenario-runner.sh + template

- [ ] **9.1** Create `templates/regression-scenarios.md`:
  ```
  ## Scenario: offline delete + online edit
  CHECK: "handleConflict" in sync-google.js
  CHECK: "tombstone" in background.js
  MANUAL: disable wifi, delete note, re-enable, verify sync
  ```
- [ ] **9.2** `scenario-runner.sh` parses `CHECK:` lines, greps for pattern in file (or full dir if no `in FILE`)
- [ ] **9.3** Output: FOUND/NOT_FOUND per check, scenario-level PASS (all found) / FAIL
- [ ] **9.4** `--json` and `--quiet` flags

### Phase 10: Test fixtures + selftest

- [ ] **10.1** Add `_selftest/plan.md` with 3 TODO items matching dir_b
- [ ] **10.2** Add `_selftest/allowlist.txt` with patterns for dir_b
- [ ] **10.3** Add `_selftest/scenarios.md` with 2 CHECK lines for dir_b
- [ ] **10.4** Create `_selftest/test.zip` from dir_b contents
- [ ] **10.5** Update run-selftest.sh:
  - v1 hardening: verify sha fallback works, diff uses awk path, unpack handles dotfiles
  - New tools: audit-plan, audit-zip, scenario-runner, audit-run
  - Composability: `--json` output parses as valid JSON, `--quiet` exit codes correct
  - Gate output present and correct

### Phase 11: README update

- [ ] **11.1** Document all new tools with usage examples
- [ ] **11.2** Add "Automation Wiring" section:
  - Pre-push hook example
  - GitHub Actions snippet
  - Define failure policy: FAIL = block, UNKNOWN = warn, PASS = proceed
- [ ] **11.3** Update "Typical Workflow" to include audit-plan, audit-zip, audit-run

---

**Do not implement yet.**
