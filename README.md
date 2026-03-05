# Auditkit

Lightweight CLI tools for verifying plan/claim drift against actual code. Hash directories, diff snapshots, verify claims, audit zips, and run regression scenarios — no dependencies beyond bash, Python 3, and optionally `rg`.

## Tools

### hash-tree.sh

SHA-256 manifest of all files in a directory.

```bash
./hash-tree.sh path/to/dir > hashes.txt
./hash-tree.sh --jsonl path/to/dir > hashes.jsonl
./hash-tree.sh --quiet path/to/dir       # no output, still runs
AUDITKIT_EXCLUDE="coverage .next" ./hash-tree.sh path/to/dir
```

Excludes `.git/`, `node_modules/`, `dist/`, `build/`, `__MACOSX/` by default. Extra excludes via `AUDITKIT_EXCLUDE` env var (space-separated). Auto-detects `shasum` (macOS) or `sha256sum` (Linux).

### diff-hash-trees.sh

Compare two hash manifests. Reports ADDED, REMOVED, CHANGED.

```bash
./diff-hash-trees.sh before.txt after.txt
./diff-hash-trees.sh --json before.txt after.txt
./diff-hash-trees.sh --quiet before.txt after.txt  # exit 0=no changes, 1=changes
```

### unpack-zip-clean.sh

Unzip, strip junk, normalize permissions, flatten single top-level dirs. Handles dotfiles, fails fast on collisions.

```bash
./unpack-zip-clean.sh archive.zip output-dir/
```

### verify-claims.py

Verify claims against a codebase using structured matching and grep.

```bash
# Freeform claims
python3 verify-claims.py claims.txt --dir path/to/code

# Plan.md TODOs (structured IDs)
python3 verify-claims.py plan.md --dir path/to/code

# Git-diff mode (only search changed files)
python3 verify-claims.py claims.txt --dir . --git-diff HEAD~1

# JSON output + gates
python3 verify-claims.py claims.txt --dir . --json report.json --gates

# Quiet mode (exit code only: 0=PASS, 1=FAIL, 2=UNKNOWN)
python3 verify-claims.py claims.txt --dir . --quiet
```

**Claim formats:**
```
- Added new-feature.js with calculateScore function       # freeform
- [TODO 2.7] add file shared/sync-google.js               # structured with ID
- remove file popup/legacy.js                              # explicit file action
- must contain "handleConflict" in sync-google.js          # literal substring check
- [ ] **1.1** Add identity permission to manifest          # plan.md checkbox
```

**Verdicts:** PASS (evidence found), FAIL (evidence contradicts), UNKNOWN (insufficient evidence), SKIP (already checked).

Evidence types: `file_exists`, `grep_hit`, `diff_hit`.

### audit-plan.sh

Read plan.md, extract unchecked TODOs, verify each against codebase.

```bash
./audit-plan.sh plan.md --dir path/to/code
./audit-plan.sh plan.md --dir . --git-diff HEAD~3 --gates
./audit-plan.sh plan.md --dir . --todo-regex '^- \[ \] \*\*'  # custom regex
```

### audit-zip.sh

Audit zip contents against an allowlist. Reports unexpected files, missing required files, and size anomalies.

```bash
./audit-zip.sh extension.zip allowlist.txt
./audit-zip.sh extension.zip allowlist.txt --source-dir src/ --max-file-kb 200
./audit-zip.sh --json extension.zip allowlist.txt
./audit-zip.sh --quiet extension.zip allowlist.txt  # exit 0=pass, 1=fail
```

**Allowlist format:**
```
!manifest.json          # required (must exist)
popup.html              # allowed (may exist)
icons/*.png             # glob pattern
lib/*.js
# comment line
```

### scenario-runner.sh

Run regression scenario checks against a codebase.

```bash
./scenario-runner.sh scenarios.md --dir path/to/code
./scenario-runner.sh --json scenarios.md --dir path/to/code
```

**Scenario format:**
```markdown
## Scenario: sync conflict handling
CHECK: "handleConflict" in sync-google.js
CHECK: "tombstone" in background.js
CHECK_NOT: "eval" in popup.js
MANUAL: disable wifi, delete note, re-enable, verify sync
```

`CHECK:` = must be found, `CHECK_NOT:` = must NOT be found (anti-regression), `MANUAL:` = informational.

### snapshot-wrap.sh

Interactive: hash before, pause for changes, hash after, diff.

```bash
./snapshot-wrap.sh path/to/dir
./snapshot-wrap.sh path/to/dir --claims claims.txt
./snapshot-wrap.sh path/to/dir --plan plan.md
```

Captures git HEAD before/after if in a repo. Saves all artifacts to `/tmp/auditkit-session-TIMESTAMP/`.

### audit-run.sh

Single-command orchestrator. Runs the full pipeline, writes `AUDIT_REPORT.md` + `AUDIT_REPORT.json`.

```bash
./audit-run.sh --dir path/to/code --claims claims.txt
./audit-run.sh --dir . --plan plan.md --claims claims.txt
./audit-run.sh --dir . --zip dist.zip --allowlist allowlist.txt
./audit-run.sh --dir . --plan plan.md --before-hash snapshot.txt --out-dir ./reports --strict
```

Exit code: 0=all gates pass, 1=any gate fails. `--strict` treats WARN as FAIL.

## Typical Workflow

```bash
# 1. Snapshot before changes
./hash-tree.sh project/ > before.txt

# 2. (changes happen)

# 3. Verify plan items were implemented
./audit-plan.sh plan.md --dir project/ --gates

# 4. See what actually changed
./hash-tree.sh project/ > after.txt
./diff-hash-trees.sh before.txt after.txt

# 5. Audit the zip before shipping
./audit-zip.sh dist/extension-chrome.zip allowlist.txt --source-dir project/

# 6. Run regression checks
./scenario-runner.sh scenarios.md --dir project/

# 7. Or run everything at once
./audit-run.sh --dir project/ --plan plan.md --zip dist.zip --allowlist allowlist.txt --out-dir ./audit-reports
```

## Automation Wiring

### Pre-push hook

```bash
#!/bin/bash
# .git/hooks/pre-push
./auditkit/audit-run.sh --dir . --plan plan.md --strict
```

### GitHub Actions

```yaml
- name: Audit
  run: |
    ./auditkit/audit-run.sh \
      --dir . \
      --plan plan.md \
      --claims claims.txt \
      --out-dir ./audit-reports \
      --strict
- name: Upload report
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: audit-report
    path: ./audit-reports/
```

### Failure policy

| Verdict | Exit code | Default | With --strict |
|---------|-----------|---------|---------------|
| PASS    | 0         | proceed | proceed       |
| UNKNOWN | 2         | warn    | block         |
| FAIL    | 1         | block   | block         |

## Composability

All tools support `--json` (or `--jsonl` for hash-tree) and `--quiet` flags. Chain them in scripts or pipe JSON to `jq`:

```bash
./diff-hash-trees.sh --json before.txt after.txt | jq '.added[]'
./audit-zip.sh --json ext.zip allowlist.txt | jq '.unexpected'
```

## Self-Test

```bash
./run-selftest.sh
```

Runs all tools against fixtures in `_selftest/`. Asserts exit codes, JSON validity, and deterministic output.

## Requirements

- bash 3.2+ (macOS default works)
- Python 3.6+
- `shasum` (macOS) or `sha256sum` (Linux)
- `rg` (ripgrep) optional, falls back to `grep -r`

## License

MIT
