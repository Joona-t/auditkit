#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0

assert_contains() {
  local LABEL="$1" FILE="$2" PATTERN="$3"
  if grep -q "$PATTERN" "$FILE"; then
    echo "  PASS: $LABEL"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $LABEL (expected '$PATTERN')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local LABEL="$1" FILE="$2" PATTERN="$3"
  if grep -q "$PATTERN" "$FILE"; then
    echo "  FAIL: $LABEL (did not expect '$PATTERN')"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $LABEL"
    PASS=$((PASS + 1))
  fi
}

assert_exit_code() {
  local LABEL="$1" EXPECTED="$2" ACTUAL="$3"
  if [ "$EXPECTED" -eq "$ACTUAL" ]; then
    echo "  PASS: $LABEL (exit $ACTUAL)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $LABEL (expected exit $EXPECTED, got $ACTUAL)"
    FAIL=$((FAIL + 1))
  fi
}

assert_valid_json() {
  local LABEL="$1" FILE="$2"
  if python3 -m json.tool "$FILE" >/dev/null 2>&1; then
    echo "  PASS: $LABEL"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $LABEL (invalid JSON)"
    FAIL=$((FAIL + 1))
  fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== Auditkit v2 Self-Test ==="
echo ""

# ─── 1. Hash tree ───
echo "--- hash-tree ---"
./hash-tree.sh _selftest/dir_a > "$TMPDIR/hash_a.txt"
./hash-tree.sh _selftest/dir_b > "$TMPDIR/hash_b.txt"
assert_contains "dir_a has hello.txt" "$TMPDIR/hash_a.txt" "hello.txt"
assert_contains "dir_a has sub/code.js" "$TMPDIR/hash_a.txt" "sub/code.js"
assert_contains "dir_b has new-feature.js" "$TMPDIR/hash_b.txt" "new-feature.js"

# JSONL mode
./hash-tree.sh --jsonl _selftest/dir_a > "$TMPDIR/hash_a.jsonl"
assert_contains "jsonl has hash key" "$TMPDIR/hash_a.jsonl" '"hash"'
assert_contains "jsonl has path key" "$TMPDIR/hash_a.jsonl" '"path"'

# Quiet mode (no output)
./hash-tree.sh --quiet _selftest/dir_a > "$TMPDIR/hash_quiet.txt"
QUIET_LINES=$(wc -l < "$TMPDIR/hash_quiet.txt" | tr -d ' ')
if [ "$QUIET_LINES" -eq 0 ]; then
  echo "  PASS: quiet mode produces no output"
  PASS=$((PASS + 1))
else
  echo "  FAIL: quiet mode produced $QUIET_LINES lines"
  FAIL=$((FAIL + 1))
fi

# AUDITKIT_EXCLUDE env var
AUDITKIT_EXCLUDE="sub" ./hash-tree.sh _selftest/dir_a > "$TMPDIR/hash_exclude.txt"
assert_not_contains "exclude filters sub/" "$TMPDIR/hash_exclude.txt" "sub/code.js"
echo ""

# ─── 2. Diff hash trees ───
echo "--- diff-hash-trees ---"
./diff-hash-trees.sh "$TMPDIR/hash_a.txt" "$TMPDIR/hash_b.txt" > "$TMPDIR/diff.txt"
assert_contains "detects ADDED" "$TMPDIR/diff.txt" "ADDED"
assert_contains "detects CHANGED" "$TMPDIR/diff.txt" "CHANGED"
assert_contains "new-feature.js added" "$TMPDIR/diff.txt" "new-feature.js"
assert_contains "hello.txt changed" "$TMPDIR/diff.txt" "hello.txt"

# JSON mode
./diff-hash-trees.sh --json "$TMPDIR/hash_a.txt" "$TMPDIR/hash_b.txt" > "$TMPDIR/diff.json" || true
assert_valid_json "diff json valid" "$TMPDIR/diff.json"
assert_contains "json has added" "$TMPDIR/diff.json" '"added"'

# Quiet mode — exit 1 if changes
EXIT=0
./diff-hash-trees.sh --quiet "$TMPDIR/hash_a.txt" "$TMPDIR/hash_b.txt" > /dev/null 2>&1 || EXIT=$?
assert_exit_code "quiet exit 1 on changes" 1 "$EXIT"

# Quiet mode — exit 0 if no changes
EXIT=0
./diff-hash-trees.sh --quiet "$TMPDIR/hash_a.txt" "$TMPDIR/hash_a.txt" > /dev/null 2>&1 || EXIT=$?
assert_exit_code "quiet exit 0 on no changes" 0 "$EXIT"

# Determinism: run twice, compare
./diff-hash-trees.sh "$TMPDIR/hash_a.txt" "$TMPDIR/hash_b.txt" > "$TMPDIR/diff_run2.txt"
if diff -q "$TMPDIR/diff.txt" "$TMPDIR/diff_run2.txt" >/dev/null 2>&1; then
  echo "  PASS: deterministic output"
  PASS=$((PASS + 1))
else
  echo "  FAIL: non-deterministic output"
  FAIL=$((FAIL + 1))
fi
echo ""

# ─── 3. Verify claims (v1 compat) ───
echo "--- verify-claims (freeform) ---"
EXIT=0
python3 ./verify-claims.py _selftest/claims.txt --dir _selftest/dir_b > "$TMPDIR/claims.txt" 2>&1 || EXIT=$?
assert_contains "claim 1 PASS" "$TMPDIR/claims.txt" "PASS"
assert_contains "has new-feature.js" "$TMPDIR/claims.txt" "new-feature.js"
assert_contains "has hello.txt" "$TMPDIR/claims.txt" "hello.txt"
assert_contains "has legacy-utils" "$TMPDIR/claims.txt" "legacy-utils"

# Evidence types
assert_contains "evidence type shown" "$TMPDIR/claims.txt" "\[file_exists\]\|grep_hit\|diff_hit"

# JSON output
EXIT=0
python3 ./verify-claims.py _selftest/claims.txt --dir _selftest/dir_b --json "$TMPDIR/claims.json" > /dev/null 2>&1 || EXIT=$?
assert_valid_json "claims json valid" "$TMPDIR/claims.json"
assert_contains "json has claim_id" "$TMPDIR/claims.json" '"claim_id"'
assert_contains "json has evidence" "$TMPDIR/claims.json" '"evidence"'

# Quiet exit codes
EXIT=0
python3 ./verify-claims.py _selftest/claims.txt --dir _selftest/dir_b --quiet > /dev/null 2>&1 || EXIT=$?
# claims.txt has all PASS, so exit 0
assert_exit_code "quiet claims exit 0" 0 "$EXIT"
echo ""

# ─── 4. Verify claims (structured + plan format) ───
echo "--- verify-claims (structured) ---"
EXIT=0
python3 ./verify-claims.py _selftest/plan.md --dir _selftest/dir_b > "$TMPDIR/plan_claims.txt" 2>&1 || EXIT=$?
assert_contains "plan ID 1.1" "$TMPDIR/plan_claims.txt" "1.1"
assert_contains "plan ID 1.2" "$TMPDIR/plan_claims.txt" "1.2"
assert_contains "plan SKIP for checked" "$TMPDIR/plan_claims.txt" "SKIP"
assert_contains "plan has PASS" "$TMPDIR/plan_claims.txt" "PASS"
echo ""

# ─── 5. Audit plan ───
echo "--- audit-plan ---"
EXIT=0
./audit-plan.sh _selftest/plan.md --dir _selftest/dir_b > "$TMPDIR/audit_plan.txt" 2>&1 || EXIT=$?
assert_contains "audit-plan has TODO IDs" "$TMPDIR/audit_plan.txt" "1.1\|1.2"
assert_contains "audit-plan has PASS" "$TMPDIR/audit_plan.txt" "PASS"
echo ""

# ─── 6. Audit zip ───
echo "--- audit-zip ---"
EXIT=0
./audit-zip.sh _selftest/test.zip _selftest/allowlist.txt > "$TMPDIR/audit_zip.txt" 2>&1 || EXIT=$?
assert_contains "zip audit GATES" "$TMPDIR/audit_zip.txt" "GATES"
assert_contains "zip audit required present" "$TMPDIR/audit_zip.txt" "PASS.*required\|All files"

# JSON mode
EXIT=0
./audit-zip.sh --json _selftest/test.zip _selftest/allowlist.txt > "$TMPDIR/audit_zip.json" 2>&1 || EXIT=$?
assert_valid_json "zip json valid" "$TMPDIR/audit_zip.json"
echo ""

# ─── 7. Scenario runner ───
echo "--- scenario-runner ---"
EXIT=0
./scenario-runner.sh _selftest/scenarios.md --dir _selftest/dir_b > "$TMPDIR/scenarios.txt" 2>&1 || EXIT=$?
assert_contains "scenario FOUND calculateScore" "$TMPDIR/scenarios.txt" "FOUND.*calculateScore\|calculateScore"
assert_contains "scenario FOUND greet" "$TMPDIR/scenarios.txt" "FOUND.*greet\|greet"
assert_contains "scenario eval absent" "$TMPDIR/scenarios.txt" "PASS.*eval\|correctly absent"
assert_exit_code "scenario-runner exit 0" 0 "$EXIT"

# JSON mode
EXIT=0
./scenario-runner.sh --json _selftest/scenarios.md --dir _selftest/dir_b > "$TMPDIR/scenarios.json" 2>&1 || EXIT=$?
assert_valid_json "scenario json valid" "$TMPDIR/scenarios.json"
echo ""

# ─── 8. Audit run (orchestrator) ───
echo "--- audit-run ---"
EXIT=0
./audit-run.sh --dir _selftest/dir_b --claims _selftest/claims.txt > "$TMPDIR/audit_run.txt" 2>&1 || EXIT=$?
assert_contains "audit-run AUDIT COMPLETE" "$TMPDIR/audit_run.txt" "AUDIT COMPLETE"
assert_contains "audit-run Overall" "$TMPDIR/audit_run.txt" "Overall:"

# Check report files were created
REPORT_DIR=$(grep "AUDIT_REPORT.md" "$TMPDIR/audit_run.txt" | head -1 | sed 's|.*Reports: ||' | xargs)
if [ -f "$REPORT_DIR" ]; then
  echo "  PASS: AUDIT_REPORT.md created"
  PASS=$((PASS + 1))
  JSON_DIR=$(dirname "$REPORT_DIR")/AUDIT_REPORT.json
  assert_valid_json "audit-run json valid" "$JSON_DIR"
else
  # Try alternate path extraction
  REPORT_DIR=$(grep -o '/tmp/auditkit-run-[^ ]*' "$TMPDIR/audit_run.txt" | head -1)
  if [ -f "$REPORT_DIR/AUDIT_REPORT.md" ]; then
    echo "  PASS: AUDIT_REPORT.md created"
    PASS=$((PASS + 1))
    assert_valid_json "audit-run json valid" "$REPORT_DIR/AUDIT_REPORT.json"
  else
    echo "  FAIL: AUDIT_REPORT.md not found"
    FAIL=$((FAIL + 1))
  fi
fi
echo ""

# ─── Summary ───
echo "==========================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "SELF-TEST FAILED"
  exit 1
else
  echo "ALL TESTS PASSED"
fi
