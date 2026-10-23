#!/bin/sh
set -eu
if [ "${FAKE_INSTALL_FAIL:-0}" != 0 ]; then echo 'sha256 digest mismatch' >&2; exit 1; fi
mkdir -p "$CRIER_BIN_DIR"
cp "$FAKE_INSTALL_SOURCE" "$CRIER_BIN_DIR/crier"
chmod +x "$CRIER_BIN_DIR/crier"
printf 'installed crier %s\n' "$CRIER_VERSION"
