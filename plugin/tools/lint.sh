#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
luacheck src tools spec
if rg -n '(^|[^[:alnum:]_.:])error\s*\(|os\.execute|io\.popen' src; then
  echo 'Forbidden runtime call' >&2
  exit 1
fi
