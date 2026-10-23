#!/bin/sh
set -eu
printf 'released=true\nversion=%s\n' "$DISPAT_NEW_VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
