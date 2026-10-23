#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
luajit tools/bundle.lua dist/crier-obs.lua 1.1.0-rc.0
LUA_PATH=';;' luajit -bl dist/crier-obs.lua >/dev/null
luajit tools/smoke.lua dist/crier-obs.lua --version 1.1.0-rc.0 --pin "$(cat crier.version)"
