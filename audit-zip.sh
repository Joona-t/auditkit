#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
JSON=false
QUIET=false
SOURCE_DIR=""
MAX_FILE_KB=500
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --source-dir) SOURCE_DIR="$2"; shift 2 ;;
    --max-file-kb) MAX_FILE_KB="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

ZIP_FILE="${1:?Usage: audit-zip.sh <zipfile> <allowlist> [--source-dir DIR] [--max-file-kb N] [--json] [--quiet]}"
ALLOWLIST="${2:?Usage: audit-zip.sh <zipfile> <allowlist>}"

if [ ! -f "$ZIP_FILE" ]; then
  echo "ERROR: '$ZIP_FILE' not found" >&2
  exit 1
fi
if [ ! -f "$ALLOWLIST" ]; then
  echo "ERROR: '$ALLOWLIST' not found" >&2
  exit 1
fi

# Unpack zip
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
"$SCRIPT_DIR/unpack-zip-clean.sh" "$ZIP_FILE" "$TMPDIR/unpacked" >/dev/null

# Parse allowlist: !pattern = required, pattern = allowed, # = comment
REQUIRED=()
ALLOWED=()
while IFS= read -r line; do
  # Strip comments and whitespace
  line=$(echo "$line" | sed 's/#.*//' | xargs)
  [ -z "$line" ] && continue
  if [[ "$line" == "!"* ]]; then
    PATTERN="${line#!}"
    REQUIRED+=("$PATTERN")
    ALLOWED+=("$PATTERN")
  else
    ALLOWED+=("$line")
  fi
done < "$ALLOWLIST"

cd "$TMPDIR/unpacked"
ALL_FILES=$(find . -type f | sed 's|^\./||' | sort)

# Check for unexpected files (not matching any allowed glob)
UNEXPECTED=()
while IFS= read -r file; do
  [ -z "$file" ] && continue
  MATCHED=false
  for pattern in "${ALLOWED[@]}"; do
    # Bash glob match against full path and basename
    case "$file" in $pattern) MATCHED=true; break ;; esac
    case "$(basename "$file")" in $pattern) MATCHED=true; break ;; esac
  done
  if ! $MATCHED; then
    UNEXPECTED+=("$file")
  fi
done <<< "$ALL_FILES"

# Check for missing required files
MISSING=()
for req in "${REQUIRED[@]}"; do
  FOUND=false
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in $req) FOUND=true; break ;; esac
  done <<< "$ALL_FILES"
  if ! $FOUND; then
    MISSING+=("$req")
  fi
done

# Check for size anomalies
SIZE_ANOMALIES=()
MAX_BYTES=$((MAX_FILE_KB * 1024))
while IFS= read -r file; do
  [ -z "$file" ] && continue
  SIZE=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    SIZE_KB=$((SIZE / 1024))
    SIZE_ANOMALIES+=("$file (${SIZE_KB}KB)")
  fi
done <<< "$ALL_FILES"

# Source diff
SOURCE_DIFF=""
if [ -n "$SOURCE_DIR" ]; then
  "$SCRIPT_DIR/hash-tree.sh" "$TMPDIR/unpacked" > "$TMPDIR/zip-hashes.txt"
  "$SCRIPT_DIR/hash-tree.sh" "$SOURCE_DIR" > "$TMPDIR/source-hashes.txt"
  SOURCE_DIFF=$("$SCRIPT_DIR/diff-hash-trees.sh" "$TMPDIR/source-hashes.txt" "$TMPDIR/zip-hashes.txt" 2>&1 || true)
fi

GATE_STATUS="PASS"
if [ ${#UNEXPECTED[@]} -gt 0 ] || [ ${#MISSING[@]} -gt 0 ]; then
  GATE_STATUS="FAIL"
fi

if $QUIET; then
  if [ "$GATE_STATUS" = "FAIL" ]; then exit 1; else exit 0; fi
fi

if $JSON; then
  # Write lists to temp files for clean python parsing
  printf '%s\n' "${UNEXPECTED[@]}" > "$TMPDIR/unexpected.txt" 2>/dev/null || touch "$TMPDIR/unexpected.txt"
  printf '%s\n' "${MISSING[@]}" > "$TMPDIR/missing.txt" 2>/dev/null || touch "$TMPDIR/missing.txt"
  printf '%s\n' "${SIZE_ANOMALIES[@]}" > "$TMPDIR/anomalies.txt" 2>/dev/null || touch "$TMPDIR/anomalies.txt"
  python3 -c "
import json
def read_list(path):
    with open(path) as f:
        return [l.strip() for l in f if l.strip()]
result = {
    'unexpected': read_list('$TMPDIR/unexpected.txt'),
    'missing': read_list('$TMPDIR/missing.txt'),
    'size_anomalies': read_list('$TMPDIR/anomalies.txt'),
    'gate': '$GATE_STATUS',
}
print(json.dumps(result, indent=2))"
  if [ "$GATE_STATUS" = "FAIL" ]; then exit 1; else exit 0; fi
fi

# Human-readable output
echo "=== Zip Audit: $(basename "$ZIP_FILE") ==="
echo ""

if [ ${#UNEXPECTED[@]} -gt 0 ]; then
  echo "UNEXPECTED (${#UNEXPECTED[@]}):"
  for f in "${UNEXPECTED[@]}"; do echo "  $f"; done
  echo ""
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "MISSING (${#MISSING[@]}):"
  for f in "${MISSING[@]}"; do echo "  $f"; done
  echo ""
fi

if [ ${#SIZE_ANOMALIES[@]} -gt 0 ]; then
  echo "SIZE_ANOMALY (${#SIZE_ANOMALIES[@]}):"
  for f in "${SIZE_ANOMALIES[@]}"; do echo "  $f"; done
  echo ""
fi

if [ ${#UNEXPECTED[@]} -eq 0 ] && [ ${#MISSING[@]} -eq 0 ] && [ ${#SIZE_ANOMALIES[@]} -eq 0 ]; then
  echo "All files match allowlist. No anomalies."
  echo ""
fi

if [ -n "$SOURCE_DIFF" ]; then
  echo "=== Source vs Zip Diff ==="
  echo "$SOURCE_DIFF"
  echo ""
fi

echo "GATES:"
if [ ${#MISSING[@]} -eq 0 ]; then
  echo "  PASS: all required files present"
else
  echo "  FAIL: ${#MISSING[@]} required file(s) missing"
fi
if [ ${#UNEXPECTED[@]} -eq 0 ]; then
  echo "  PASS: no unexpected files"
else
  echo "  FAIL: ${#UNEXPECTED[@]} unexpected file(s)"
fi
if [ ${#SIZE_ANOMALIES[@]} -eq 0 ]; then
  echo "  PASS: no size anomalies"
else
  echo "  WARN: ${#SIZE_ANOMALIES[@]} file(s) exceed ${MAX_FILE_KB}KB"
fi

if [ "$GATE_STATUS" = "FAIL" ]; then exit 1; fi
