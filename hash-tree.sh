#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

# Parse flags
JSONL=false
QUIET=false
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jsonl) JSONL=true; shift ;;
    --quiet) QUIET=true; shift ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

DIR="${1:?Usage: hash-tree.sh [--jsonl] [--quiet] <directory>}"

if [ ! -d "$DIR" ]; then
  echo "ERROR: '$DIR' is not a directory" >&2
  exit 1
fi

# SHA command detection
if command -v shasum >/dev/null 2>&1; then
  SHA_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD="sha256sum"
else
  echo "ERROR: neither shasum nor sha256sum found" >&2
  exit 1
fi

# Build exclude list (defaults + env var)
DEFAULT_EXCLUDES=".git node_modules dist build __MACOSX"
EXCLUDES="$DEFAULT_EXCLUDES"
if [ -n "$AUDITKIT_EXCLUDE" ]; then
  EXCLUDES="$EXCLUDES $AUDITKIT_EXCLUDE"
fi

cd "$DIR"

# Build find exclude args (indexed arrays work in bash 3.2)
FIND_ARGS=()
for EX in $EXCLUDES; do
  FIND_ARGS+=(-not -path "./$EX/*")
done

find . -type f "${FIND_ARGS[@]}" | sort | while read -r FILE; do
  HASH=$($SHA_CMD "$FILE" | cut -d' ' -f1)
  RELPATH="${FILE#./}"
  if $JSONL; then
    printf '{"hash":"%s","path":"%s"}\n' "$HASH" "$RELPATH"
  elif ! $QUIET; then
    echo "$HASH  $RELPATH"
  fi
done
