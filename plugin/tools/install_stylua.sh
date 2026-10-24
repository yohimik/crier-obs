#!/bin/sh
# Installs the pinned StyLua release binary on a Linux runner (macOS runners use Homebrew).
# The lint gate formats with whatever stylua is on PATH, so CI pins the version that wrote the tree.
set -eu
version=2.6.0
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset=stylua-linux-x86_64.zip; sha256=a485f72bbfa22e4642e77a84b5edc2611a5cab7477b34e2e709dd8f78e919895 ;;
  Linux-aarch64) asset=stylua-linux-aarch64.zip; sha256=8e67539e5fdf7a81cd03cf592b0df18d3bb96ee17a5ea5d9bf67b86387b903b0 ;;
  *) echo "install_stylua: no pinned StyLua build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
dir=${1:?usage: install_stylua.sh <bin-dir>}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/JohnnyMorganz/StyLua/releases/download/v$version/$asset" -o "$tmp/$asset"
printf '%s  %s\n' "$sha256" "$tmp/$asset" | sha256sum -c - >/dev/null
unzip -q "$tmp/$asset" -d "$tmp/out"
binary=$(find "$tmp/out" -type f -name stylua | head -n 1)
[ -n "$binary" ] || { echo "install_stylua: $asset holds no stylua binary" >&2; exit 1; }
mkdir -p "$dir"
install -m 0755 "$binary" "$dir/stylua"
installed=$("$dir/stylua" --version)
[ "$installed" = "stylua $version" ] || { echo "install_stylua: got $installed, want $version" >&2; exit 1; }
echo "$installed"
