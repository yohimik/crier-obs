#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
version=0.0.0-ci
luajit tools/bundle.lua dist/crier-obs.lua "$version"
# -b loads jit.bcsave through the default path, which a luarocks LUA_PATH without ';;' hides.
LUA_PATH=';;' luajit -bl dist/crier-obs.lua >/dev/null
# The smoke proves the modules this host loads or the bundle names; this proves every source module ships.
modules=$(find src/crier_obs -type f -name '*.lua' | sed -e 's#^src/##' -e 's#\.lua$##' -e 's#/#.#g' | sort)
bundled=$(sed -n 's/^package\.preload\["\([^"]*\)"\]=function.*/\1/p' dist/crier-obs.lua | sort)
if [ "$modules" != "$bundled" ]; then
  echo 'bundle modules differ from src/crier_obs' >&2
  exit 1
fi
luajit tools/smoke.lua dist/crier-obs.lua --version "$version" --pin "$(cat crier.version)"
# The end-to-end specs once more, loading every module from the bundle rather than src/.
CRIER_OBS_E2E_BUNDLE=dist/crier-obs.lua busted --lua=luajit --helper=spec/helper.lua spec/e2e
