#!/bin/bash
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

ZIP_FILE="${1:?Usage: unpack-zip-clean.sh <zipfile> <output-dir>}"
OUT_DIR="${2:?Usage: unpack-zip-clean.sh <zipfile> <output-dir>}"

if [ ! -f "$ZIP_FILE" ]; then
  echo "ERROR: '$ZIP_FILE' not found" >&2
  exit 1
fi

# Fail if output dir exists and is non-empty
if [ -d "$OUT_DIR" ] && [ "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
  echo "ERROR: output directory '$OUT_DIR' already exists and is not empty" >&2
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

unzip -q "$ZIP_FILE" -d "$TMPDIR"

# Clean junk
find "$TMPDIR" -name '__MACOSX' -type d -exec rm -rf {} + 2>/dev/null || true
find "$TMPDIR" -name '.DS_Store' -delete 2>/dev/null || true
find "$TMPDIR" -name '*.pyc' -delete 2>/dev/null || true
find "$TMPDIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# Normalize permissions
find "$TMPDIR" -type f -exec chmod 644 {} +
find "$TMPDIR" -type d -exec chmod 755 {} +

# Flatten if single top-level directory
ENTRIES=("$TMPDIR"/*)
if [ ${#ENTRIES[@]} -eq 1 ] && [ -d "${ENTRIES[0]}" ]; then
  INNER="${ENTRIES[0]}"
  mkdir -p "$OUT_DIR"
  # Enable dotglob to catch dotfiles, nullglob for empty dirs
  shopt -s dotglob nullglob
  INNER_FILES=("$INNER"/*)
  if [ ${#INNER_FILES[@]} -gt 0 ]; then
    mv "${INNER_FILES[@]}" "$OUT_DIR"/
  fi
  shopt -u dotglob nullglob
else
  mkdir -p "$OUT_DIR"
  shopt -s dotglob nullglob
  TMPFILES=("$TMPDIR"/*)
  if [ ${#TMPFILES[@]} -gt 0 ]; then
    mv "${TMPFILES[@]}" "$OUT_DIR"/
  fi
  shopt -u dotglob nullglob
fi

echo "Unpacked to: $OUT_DIR"
