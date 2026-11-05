#!/usr/bin/env bash
# Builds dist/WowFriendly-<version>.zip for a GitHub release.
# The zip holds a top-level WowFriendly/ folder, so it extracts straight into Interface/AddOns/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^## Version: *//p' "$ROOT/WowFriendly/WowFriendly.toc" | tr -d '\r')"
[[ -n "$VERSION" ]] || { echo "could not read version from TOC" >&2; exit 1; }
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/WowFriendly-$VERSION.zip"
python3 - "$ROOT/WowFriendly" "$OUT" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith((".swp", ".DS_Store")):
                continue
            full = os.path.join(dirpath, name)
            arc = os.path.join("WowFriendly", os.path.relpath(full, src))
            z.write(full, arc)
PY
echo "wrote $OUT ($(stat -c %s "$OUT") bytes)"
