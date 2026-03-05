#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags — pass through to verify-claims.py
PASSTHROUGH=()
PLAN_FILE=""
DIR=""
TODO_REGEX='^- \[ \] \*\*'

while [ $# -gt 0 ]; do
  case "$1" in
    --json|--quiet|--gates) PASSTHROUGH+=("$1"); shift ;;
    --git-diff)
      shift
      if [ $# -gt 0 ] && [[ "$1" != --* ]] && [[ "$1" != *.md ]]; then
        PASSTHROUGH+=("--git-diff" "$1"); shift
      else
        PASSTHROUGH+=("--git-diff")
      fi
      ;;
    --dir) DIR="$2"; shift 2 ;;
    --todo-regex) TODO_REGEX="$2"; shift 2 ;;
    *) PLAN_FILE="$1"; shift ;;
  esac
done

PLAN_FILE="${PLAN_FILE:?Usage: audit-plan.sh <plan.md> --dir <directory> [--json FILE] [--quiet] [--gates] [--git-diff REF] [--todo-regex REGEX]}"
DIR="${DIR:?Usage: audit-plan.sh <plan.md> --dir <directory>}"

if [ ! -f "$PLAN_FILE" ]; then
  echo "ERROR: '$PLAN_FILE' not found" >&2
  exit 1
fi
if [ ! -d "$DIR" ]; then
  echo "ERROR: '$DIR' is not a directory" >&2
  exit 1
fi

# Extract unchecked TODOs from plan
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

grep -E "$TODO_REGEX" "$PLAN_FILE" > "$TMPFILE" || true

if [ ! -s "$TMPFILE" ]; then
  echo "No unchecked TODOs found in $PLAN_FILE"
  exit 0
fi

# Run verify-claims on extracted TODOs
python3 "$SCRIPT_DIR/verify-claims.py" "$TMPFILE" --dir "$DIR" "${PASSTHROUGH[@]}"
