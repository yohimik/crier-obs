#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
rm -f luacov.stats.out luacov.report.out
busted --lua=luajit --helper=spec/helper.lua spec "$@"
luajit tools/coverage_gate.lua
