#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
pin=$(cat crier.version)
cache="$PWD/.cache/v$pin"
mkdir -p "$cache"
source=${CRIER_SOURCE:-$cache/source}
if [ ! -d "$source/.git" ]; then git clone --quiet --depth 1 --branch "v$pin" https://github.com/yohimik/crier.git "$source"; fi
case "$(uname -s)" in Darwin) platform=darwin ;; Linux) platform=linux ;; *) echo 'Registry gate requires POSIX runner' >&2; exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) exit 1 ;; esac
if [ ! -s "$cache/release.json" ]; then
  # Unauthenticated API calls share 60 an hour per address; the token header goes through stdin, not argv.
  fetch() {
    curl -fsSL -H 'Accept: application/vnd.github+json' "$@" \
      "https://api.github.com/repos/yohimik/crier/releases/tags/v$pin" -o "$cache/release.json.part"
  }
  token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
  if [ -n "$token" ]; then printf 'Authorization: Bearer %s\n' "$token" | fetch -H @-; else fetch; fi
  mv "$cache/release.json.part" "$cache/release.json"
fi
if [ ! -x "$cache/crier" ]; then
  curl -fsSL "https://github.com/yohimik/crier/releases/download/v$pin/crier-$platform-$arch" -o "$cache/crier"
  chmod +x "$cache/crier"
fi
luajit tools/verify_digest.lua "$cache/release.json" "crier-$platform-$arch" "$cache/crier"
"$cache/crier" init --full --format json --force --output "$cache/init.json"
cp src/crier_obs/registry/keys.lua "$cache/keys.lua"
cp src/crier_obs/registry/custom.lua "$cache/custom.lua"
cp src/crier_obs/registry/meta.lua "$cache/meta.lua"
luajit tools/gen_registry.lua "$source" "$cache/init.json"
for name in keys custom meta; do cmp "src/crier_obs/registry/$name.lua" "$cache/$name.lua"; done
