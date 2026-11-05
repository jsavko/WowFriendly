#!/usr/bin/env bash
# Build a project-local Lua 5.1 interpreter (lua + luac) into .tools/ without sudo.
# Only used for the offline tests and the syntax check; the addon itself needs no build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
VER="5.1.5"
TARBALL="lua-$VER.tar.gz"
URL="https://www.lua.org/ftp/$TARBALL"
SHA256="2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333"

if [[ -x "$TOOLS/lua" && -x "$TOOLS/luac" ]]; then
  echo "lua already built: $("$TOOLS/lua" -v 2>&1)"
  exit 0
fi

mkdir -p "$TOOLS/build"
cd "$TOOLS/build"

if [[ ! -f "$TARBALL" ]]; then
  echo "Downloading $URL"
  curl -fsSL -o "$TARBALL" "$URL"
fi

echo "$SHA256  $TARBALL" | sha256sum -c -

rm -rf "lua-$VER"
tar xzf "$TARBALL"
cd "lua-$VER"
make -s generic
cp src/lua src/luac "$TOOLS/"
cd "$TOOLS"
rm -rf build
echo "Built: $("$TOOLS/lua" -v 2>&1)"
