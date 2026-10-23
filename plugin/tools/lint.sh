#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
for tool in luacheck grep; do
  command -v "$tool" >/dev/null || { echo "lint: $tool missing" >&2; exit 1; }
done
luacheck src tools spec
# Runtime code must not call the global error (OBS replaces it), os.execute or io.popen.
status=0
grep -rnE '(^|[^[:alnum:]_.:])error[[:space:]]*\(|os\.execute|io\.popen' src || status=$?
case $status in
  0) echo 'Forbidden runtime call' >&2; exit 1 ;;
  1) ;;
  *) echo "lint: grep failed with status $status" >&2; exit "$status" ;;
esac
