#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
DIR=""
PLAN=""
CLAIMS=""
ZIP=""
ALLOWLIST=""
BEFORE_HASH=""
OUT_DIR=""
STRICT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --plan) PLAN="$2"; shift 2 ;;
    --claims) CLAIMS="$2"; shift 2 ;;
    --zip) ZIP="$2"; shift 2 ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
    --before-hash) BEFORE_HASH="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --strict) STRICT=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

DIR="${DIR:?Usage: audit-run.sh --dir <directory> [--plan FILE] [--claims FILE] [--zip FILE --allowlist FILE] [--before-hash FILE] [--out-dir DIR] [--strict]}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${OUT_DIR:-/tmp/auditkit-run-$TIMESTAMP}"
mkdir -p "$OUT_DIR"

GATE_RESULTS=()
MD_REPORT="$OUT_DIR/AUDIT_REPORT.md"

echo "# Audit Report — $TIMESTAMP" > "$MD_REPORT"
echo "" >> "$MD_REPORT"

# 1. Hash tree
echo "Hashing $DIR..."
"$SCRIPT_DIR/hash-tree.sh" "$DIR" > "$OUT_DIR/current-hashes.txt"
FILE_COUNT=$(wc -l < "$OUT_DIR/current-hashes.txt" | tr -d ' ')

echo "## Hash Tree" >> "$MD_REPORT"
echo "" >> "$MD_REPORT"
echo "$FILE_COUNT files hashed." >> "$MD_REPORT"
echo "" >> "$MD_REPORT"

# 2. Diff against before-hash
if [ -n "$BEFORE_HASH" ]; then
  echo "Diffing against $BEFORE_HASH..."
  DIFF_EXIT=0
  DIFF_OUT=$("$SCRIPT_DIR/diff-hash-trees.sh" "$BEFORE_HASH" "$OUT_DIR/current-hashes.txt" 2>&1) || DIFF_EXIT=$?

  echo "## Hash Diff" >> "$MD_REPORT"
  echo "" >> "$MD_REPORT"
  echo '```' >> "$MD_REPORT"
  echo "$DIFF_OUT" >> "$MD_REPORT"
  echo '```' >> "$MD_REPORT"
  echo "" >> "$MD_REPORT"

  if [ "$DIFF_OUT" = "NO_CHANGES" ]; then
    GATE_RESULTS+=("PASS: no unexpected file changes")
  else
    GATE_RESULTS+=("INFO: file changes detected (review diff)")
  fi
fi

# 3. Verify claims
if [ -n "$CLAIMS" ]; then
  echo "Verifying claims..."
  CLAIMS_EXIT=0
  CLAIMS_OUT=$(python3 "$SCRIPT_DIR/verify-claims.py" "$CLAIMS" --dir "$DIR" --gates 2>&1) || CLAIMS_EXIT=$?

  echo "## Claim Verification" >> "$MD_REPORT"
  echo "" >> "$MD_REPORT"
  echo "$CLAIMS_OUT" >> "$MD_REPORT"
  echo "" >> "$MD_REPORT"

  if [ $CLAIMS_EXIT -eq 0 ]; then
    GATE_RESULTS+=("PASS: all claims verified")
  elif [ $CLAIMS_EXIT -eq 1 ]; then
    GATE_RESULTS+=("FAIL: claim verification failures")
  else
    GATE_RESULTS+=("WARN: unverifiable claims present")
  fi
fi

# 4. Audit plan
if [ -n "$PLAN" ]; then
  echo "Auditing plan..."
  PLAN_EXIT=0
  PLAN_OUT=$("$SCRIPT_DIR/audit-plan.sh" "$PLAN" --dir "$DIR" --gates 2>&1) || PLAN_EXIT=$?

  echo "## Plan Audit" >> "$MD_REPORT"
  echo "" >> "$MD_REPORT"
  echo "$PLAN_OUT" >> "$MD_REPORT"
  echo "" >> "$MD_REPORT"

  if [ $PLAN_EXIT -eq 0 ]; then
    GATE_RESULTS+=("PASS: all plan items verified")
  elif [ $PLAN_EXIT -eq 1 ]; then
    GATE_RESULTS+=("FAIL: plan verification failures")
  else
    GATE_RESULTS+=("WARN: unverifiable plan items")
  fi
fi

# 5. Audit zip
if [ -n "$ZIP" ] && [ -n "$ALLOWLIST" ]; then
  echo "Auditing zip..."
  ZIP_ARGS=("$ZIP" "$ALLOWLIST")
  [ -n "$DIR" ] && ZIP_ARGS+=(--source-dir "$DIR")
  ZIP_EXIT=0
  ZIP_OUT=$("$SCRIPT_DIR/audit-zip.sh" "${ZIP_ARGS[@]}" 2>&1) || ZIP_EXIT=$?

  echo "## Zip Audit" >> "$MD_REPORT"
  echo "" >> "$MD_REPORT"
  echo "$ZIP_OUT" >> "$MD_REPORT"
  echo "" >> "$MD_REPORT"

  if [ $ZIP_EXIT -eq 0 ]; then
    GATE_RESULTS+=("PASS: zip contents match allowlist")
  else
    GATE_RESULTS+=("FAIL: zip audit failed")
  fi
fi

# Gate summary
OVERALL="PASS"
for gate in "${GATE_RESULTS[@]}"; do
  case "$gate" in
    FAIL:*) OVERALL="FAIL" ;;
    WARN:*) [ "$OVERALL" != "FAIL" ] && OVERALL="WARN" ;;
  esac
done

echo "## Gates" >> "$MD_REPORT"
echo "" >> "$MD_REPORT"
echo '```' >> "$MD_REPORT"
echo "GATES:" >> "$MD_REPORT"
for gate in "${GATE_RESULTS[@]}"; do
  echo "  $gate" >> "$MD_REPORT"
done
echo "OVERALL: $OVERALL" >> "$MD_REPORT"
echo '```' >> "$MD_REPORT"

# JSON report
python3 << PYEOF
import json

gates = []
gate_lines = """$(printf '%s\n' "${GATE_RESULTS[@]}")""".strip().split('\n')
for line in gate_lines:
    if not line.strip():
        continue
    parts = line.split(':', 1)
    if len(parts) == 2:
        gates.append({'status': parts[0].strip(), 'message': parts[1].strip()})

report = {
    'timestamp': '$TIMESTAMP',
    'directory': '$DIR',
    'overall': '$OVERALL',
    'gates': gates,
}

with open('$OUT_DIR/AUDIT_REPORT.json', 'w') as f:
    json.dump(report, f, indent=2)
PYEOF

# Print summary
echo ""
echo "=== AUDIT COMPLETE ==="
echo "Overall: $OVERALL"
for gate in "${GATE_RESULTS[@]}"; do
  echo "  $gate"
done
echo ""
echo "Reports: $OUT_DIR/AUDIT_REPORT.md"
echo "         $OUT_DIR/AUDIT_REPORT.json"

# Exit code
if [ "$OVERALL" = "FAIL" ]; then
  exit 1
elif [ "$OVERALL" = "WARN" ] && $STRICT; then
  exit 1
fi
