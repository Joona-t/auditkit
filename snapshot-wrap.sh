#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
CLAIMS=""
PLAN=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --claims) CLAIMS="$2"; shift 2 ;;
    --plan) PLAN="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

DIR="${1:?Usage: snapshot-wrap.sh <directory> [--claims FILE] [--plan FILE]}"

if [ ! -d "$DIR" ]; then
  echo "ERROR: '$DIR' is not a directory" >&2
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SESSION_DIR="/tmp/auditkit-session-$TIMESTAMP"
mkdir -p "$SESSION_DIR"

# Capture git HEAD if in a repo
if git -C "$DIR" rev-parse HEAD >/dev/null 2>&1; then
  git -C "$DIR" rev-parse HEAD > "$SESSION_DIR/git-rev-before.txt"
  echo "Git HEAD (before): $(cat "$SESSION_DIR/git-rev-before.txt")"
fi

# Before snapshot
echo "Hashing $DIR (before)..."
"$SCRIPT_DIR/hash-tree.sh" "$DIR" > "$SESSION_DIR/before.txt"
BEFORE_COUNT=$(wc -l < "$SESSION_DIR/before.txt" | tr -d ' ')
echo "$BEFORE_COUNT files hashed."

echo ""
echo "Make your changes, then press Enter."
read -r

# After snapshot
echo "Hashing $DIR (after)..."
"$SCRIPT_DIR/hash-tree.sh" "$DIR" > "$SESSION_DIR/after.txt"

# Capture git HEAD after
if [ -f "$SESSION_DIR/git-rev-before.txt" ]; then
  git -C "$DIR" rev-parse HEAD > "$SESSION_DIR/git-rev-after.txt"
  echo "Git HEAD (after): $(cat "$SESSION_DIR/git-rev-after.txt")"
fi

# Diff
echo ""
echo "=== Diff ==="
"$SCRIPT_DIR/diff-hash-trees.sh" "$SESSION_DIR/before.txt" "$SESSION_DIR/after.txt" | tee "$SESSION_DIR/diff.txt"

# Optional claims
if [ -n "$CLAIMS" ]; then
  echo ""
  echo "=== Claim Verification ==="
  EXIT=0
  python3 "$SCRIPT_DIR/verify-claims.py" "$CLAIMS" --dir "$DIR" --gates | tee "$SESSION_DIR/claims-report.txt" || EXIT=$?
fi

# Optional plan
if [ -n "$PLAN" ]; then
  echo ""
  echo "=== Plan Audit ==="
  EXIT=0
  "$SCRIPT_DIR/audit-plan.sh" "$PLAN" --dir "$DIR" --gates | tee "$SESSION_DIR/plan-report.txt" || EXIT=$?
fi

echo ""
echo "Session artifacts saved to: $SESSION_DIR"
