#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

# Parse flags
JSON=false
QUIET=false
DIR=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --dir) DIR="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

SCENARIOS_FILE="${1:?Usage: scenario-runner.sh <scenarios.md> --dir <directory> [--json] [--quiet]}"
DIR="${DIR:?Usage: scenario-runner.sh <scenarios.md> --dir <directory>}"

if [ ! -f "$SCENARIOS_FILE" ]; then
  echo "ERROR: '$SCENARIOS_FILE' not found" >&2
  exit 1
fi
if [ ! -d "$DIR" ]; then
  echo "ERROR: '$DIR' is not a directory" >&2
  exit 1
fi

SCENARIO=""
TOTAL=0
PASSED=0
FAILED=0
TMPRESULTS=$(mktemp)
trap 'rm -f "$TMPRESULTS"' EXIT

while IFS= read -r line; do
  # Scenario header
  if echo "$line" | grep -q "^## Scenario:"; then
    SCENARIO=$(echo "$line" | sed 's/^## Scenario: *//')
    if ! $QUIET && ! $JSON; then
      echo "=== $SCENARIO ==="
    fi
    continue
  fi

  # CHECK: "pattern" in file
  if echo "$line" | grep -q "^CHECK:"; then
    TOTAL=$((TOTAL + 1))
    RAW_PATTERN=$(echo "$line" | sed 's/^CHECK: *//')

    # Parse "pattern" in file — strip quotes
    PATTERN=$(echo "$RAW_PATTERN" | sed 's/"//g')
    FILE=""
    if echo "$PATTERN" | grep -q " in "; then
      FILE=$(echo "$PATTERN" | sed 's/.* in //')
      PATTERN=$(echo "$PATTERN" | sed 's/ in .*//')
    fi

    FOUND=false
    if [ -n "$FILE" ]; then
      [ -f "$DIR/$FILE" ] && grep -qF "$PATTERN" "$DIR/$FILE" 2>/dev/null && FOUND=true
    else
      grep -rqF "$PATTERN" "$DIR" 2>/dev/null && FOUND=true
    fi

    if $FOUND; then
      PASSED=$((PASSED + 1))
      if ! $QUIET && ! $JSON; then echo "  FOUND: $PATTERN${FILE:+ in $FILE}"; fi
      echo "{\"scenario\":\"$SCENARIO\",\"check\":\"CHECK\",\"pattern\":\"$PATTERN\",\"file\":\"$FILE\",\"status\":\"FOUND\"}" >> "$TMPRESULTS"
    else
      FAILED=$((FAILED + 1))
      if ! $QUIET && ! $JSON; then echo "  NOT_FOUND: $PATTERN${FILE:+ in $FILE}"; fi
      echo "{\"scenario\":\"$SCENARIO\",\"check\":\"CHECK\",\"pattern\":\"$PATTERN\",\"file\":\"$FILE\",\"status\":\"NOT_FOUND\"}" >> "$TMPRESULTS"
    fi
    continue
  fi

  # CHECK_NOT: anti-regression
  if echo "$line" | grep -q "^CHECK_NOT:"; then
    TOTAL=$((TOTAL + 1))
    RAW_PATTERN=$(echo "$line" | sed 's/^CHECK_NOT: *//')

    PATTERN=$(echo "$RAW_PATTERN" | sed 's/"//g')
    FILE=""
    if echo "$PATTERN" | grep -q " in "; then
      FILE=$(echo "$PATTERN" | sed 's/.* in //')
      PATTERN=$(echo "$PATTERN" | sed 's/ in .*//')
    fi

    FOUND=false
    if [ -n "$FILE" ]; then
      [ -f "$DIR/$FILE" ] && grep -qF "$PATTERN" "$DIR/$FILE" 2>/dev/null && FOUND=true
    else
      grep -rqF "$PATTERN" "$DIR" 2>/dev/null && FOUND=true
    fi

    if $FOUND; then
      FAILED=$((FAILED + 1))
      if ! $QUIET && ! $JSON; then echo "  FAIL: '$PATTERN' should NOT be present${FILE:+ in $FILE}"; fi
      echo "{\"scenario\":\"$SCENARIO\",\"check\":\"CHECK_NOT\",\"pattern\":\"$PATTERN\",\"file\":\"$FILE\",\"status\":\"FAIL_PRESENT\"}" >> "$TMPRESULTS"
    else
      PASSED=$((PASSED + 1))
      if ! $QUIET && ! $JSON; then echo "  PASS: '$PATTERN' correctly absent${FILE:+ from $FILE}"; fi
      echo "{\"scenario\":\"$SCENARIO\",\"check\":\"CHECK_NOT\",\"pattern\":\"$PATTERN\",\"file\":\"$FILE\",\"status\":\"PASS_ABSENT\"}" >> "$TMPRESULTS"
    fi
    continue
  fi

  # MANUAL: informational
  if echo "$line" | grep -q "^MANUAL:"; then
    if ! $QUIET && ! $JSON; then
      echo "  MANUAL: $(echo "$line" | sed 's/^MANUAL: *//')"
    fi
    continue
  fi
done < "$SCENARIOS_FILE"

# Summary
if ! $QUIET && ! $JSON; then
  echo ""
  echo "=== Results ==="
  echo "$PASSED/$TOTAL checks passed, $FAILED failed"
  if [ $FAILED -eq 0 ]; then
    echo "GATE: PASS"
  else
    echo "GATE: FAIL"
  fi
fi

if $JSON; then
  python3 -c "
import json
results = []
with open('$TMPRESULTS') as f:
    for line in f:
        if line.strip():
            results.append(json.loads(line))
print(json.dumps({
    'total': $TOTAL,
    'passed': $PASSED,
    'failed': $FAILED,
    'gate': 'PASS' if $FAILED == 0 else 'FAIL',
    'results': results,
}, indent=2))"
fi

if [ $FAILED -gt 0 ]; then
  exit 1
fi
