#!/usr/bin/env bash
# Syntax-check every addon Lua file (excluding vendored Libs) and run the offline tests.
# Needs the local Lua 5.1 built by scripts/setup-lua.sh; warns and skips if it is missing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA="$ROOT/.tools/lua"
LUAC="$ROOT/.tools/luac"

if [[ ! -x "$LUAC" || ! -x "$LUA" ]]; then
  echo "WARNING: $ROOT/.tools/lua not built; run scripts/setup-lua.sh to enable syntax checks and tests." >&2
  exit 0
fi

status=0
echo "== Syntax check =="
while IFS= read -r -d '' f; do
  if ! "$LUAC" -p "$f"; then
    status=1
  fi
done < <(find "$ROOT/WowFriendly" -name '*.lua' -not -path '*/Libs/*' -print0 | sort -z)
if [[ $status -eq 0 ]]; then echo "ok"; fi

echo "== Tests =="
if ! (cd "$ROOT" && "$LUA" tests/run.lua); then
  status=1
fi

exit $status
