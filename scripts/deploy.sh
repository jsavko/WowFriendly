#!/usr/bin/env bash
# Copy the addon into the local WoW Forever AddOns folder.
# Usage: scripts/deploy.sh [-n]   (-n = dry run, show what would change)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/WowFriendly/"
DEST="${WOW_ADDONS_DIR:-/mnt/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns}/WowFriendly/"

DRY=()
if [[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]]; then
  DRY=(--dry-run)
fi

if [[ ! -d "$(dirname "$DEST")" ]]; then
  echo "AddOns folder not found: $(dirname "$DEST")" >&2
  echo "Set WOW_ADDONS_DIR to override." >&2
  exit 1
fi

if [[ ${#DRY[@]} -eq 0 ]]; then mkdir -p "$DEST"; fi
rsync -a --delete --itemize-changes "${DRY[@]}" "$SRC" "$DEST"
echo "Deployed to $DEST${DRY:+ (dry run)}"
