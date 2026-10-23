#!/bin/sh
set -eu
command -v luajit >/dev/null || { echo 'luajit missing' >&2; exit 1; }
cd "$(dirname "$0")/.."
: "${DISPAT_NEW_VERSION:?build requires DISPAT_NEW_VERSION}"
mkdir -p dist
luajit tools/bundle.lua dist/crier-obs.lua "$DISPAT_NEW_VERSION"
luajit tools/smoke.lua dist/crier-obs.lua --version "$DISPAT_NEW_VERSION" --pin "$(cat crier.version)"
grep -F -- "-- crier-obs $DISPAT_NEW_VERSION |" dist/crier-obs.lua >/dev/null
grep -F -- "VERSION = \"$DISPAT_NEW_VERSION\"" dist/crier-obs.lua >/dev/null
if grep -F '0.0.0-dev' dist/crier-obs.lua >/dev/null; then echo 'unstamped version' >&2; exit 1; fi
printf 'DISPAT_EXPORT_GITHUB=%s/dist/crier-obs.lua\n' "$PWD" >> "${DISPAT_OUTPUT:-/dev/null}"
