#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

# Parse flags
JSON=false
QUIET=false
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --quiet) QUIET=true; shift ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

FILE_A="${1:?Usage: diff-hash-trees.sh [--json] [--quiet] <hash-file-a> <hash-file-b>}"
FILE_B="${2:?Usage: diff-hash-trees.sh [--json] [--quiet] <hash-file-a> <hash-file-b>}"

if [ ! -f "$FILE_A" ]; then
  echo "ERROR: '$FILE_A' not found" >&2
  exit 1
fi
if [ ! -f "$FILE_B" ]; then
  echo "ERROR: '$FILE_B' not found" >&2
  exit 1
fi

# Single awk pass: FNR==NR reads FILE_A, then FILE_B
# Outputs tagged lines: A <path>, R <path>, C <path>
RAW=$(awk '
FNR==NR { a[$2] = $1; next }
{ b[$2] = $1 }
END {
  for (p in b) {
    if (!(p in a)) print "A " p
    else if (a[p] != b[p]) print "C " p
  }
  for (p in a) {
    if (!(p in b)) print "R " p
  }
}
' "$FILE_A" "$FILE_B")

ADDED=$(echo "$RAW" | awk '/^A /{print substr($0,3)}' | sort)
REMOVED=$(echo "$RAW" | awk '/^R /{print substr($0,3)}' | sort)
CHANGED=$(echo "$RAW" | awk '/^C /{print substr($0,3)}' | sort)

# Trim empty lines
ADDED=$(echo "$ADDED" | sed '/^$/d')
REMOVED=$(echo "$REMOVED" | sed '/^$/d')
CHANGED=$(echo "$CHANGED" | sed '/^$/d')

HAS_CHANGES=false
if [ -n "$ADDED" ] || [ -n "$REMOVED" ] || [ -n "$CHANGED" ]; then
  HAS_CHANGES=true
fi

if $QUIET; then
  if $HAS_CHANGES; then exit 1; else exit 0; fi
fi

if $JSON; then
  python3 -c "
import json
def to_list(s):
    return [l for l in s.strip().split('\n') if l] if s.strip() else []
print(json.dumps({
    'added': to_list('''$ADDED'''),
    'removed': to_list('''$REMOVED'''),
    'changed': to_list('''$CHANGED'''),
}))"
  if $HAS_CHANGES; then exit 1; else exit 0; fi
fi

# Human-readable output
if ! $HAS_CHANGES; then
  echo "NO_CHANGES"
  exit 0
fi

if [ -n "$ADDED" ]; then
  echo "ADDED:"
  echo "$ADDED" | while IFS= read -r LINE; do echo "  $LINE"; done
fi
if [ -n "$REMOVED" ]; then
  echo "REMOVED:"
  echo "$REMOVED" | while IFS= read -r LINE; do echo "  $LINE"; done
fi
if [ -n "$CHANGED" ]; then
  echo "CHANGED:"
  echo "$CHANGED" | while IFS= read -r LINE; do echo "  $LINE"; done
fi
