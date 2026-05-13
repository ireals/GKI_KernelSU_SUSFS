#!/usr/bin/env bash
set -euo pipefail

KSU_DIR="${1:-}"
if [ -z "$KSU_DIR" ] || [ ! -d "$KSU_DIR/.git" ]; then
  echo "::error::Usage: $0 /path/to/KernelSU"
  exit 1
fi

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$KSU_DIR"
for patch in "$PATCH_DIR"/*.patch; do
  [ -e "$patch" ] || continue
  name="$(basename "$patch")"

  if git apply --check "$patch" 2>/dev/null; then
    echo "Applying $name"
    git apply --whitespace=nowarn "$patch"
  elif git apply --reverse --check "$patch" 2>/dev/null; then
    echo "Already applied $name"
  else
    echo "::error::Failed to apply $name"
    git apply --reject --whitespace=nowarn "$patch" || true
    exit 1
  fi
done
