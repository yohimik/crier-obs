#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
old=$(cat plugin/crier.version)
latest=$(gh api repos/yohimik/crier/releases/latest --jq .tag_name)
new=${latest#v}
if luajit plugin/tools/newer_pin.lua "$old" "$new"; then
  :
else
  code=$?
  [ "$code" = 3 ] && exit 0
  exit "$code"
fi
branch="codex/crier-$new"
if gh pr list --head "$branch" --json number --jq '.[0].number' | grep '[0-9]' >/dev/null; then exit 0; fi
git switch -c "$branch"
printf '%s\n' "$new" > plugin/crier.version
# Documentation and install version always move with the registry pin.
mkdir -p "plugin/.cache/v$new"
git clone --quiet --depth 1 --branch "v$new" https://github.com/yohimik/crier.git "plugin/.cache/v$new/source"
(cd plugin && luajit tools/gen_registry.lua ".cache/v$new/source")
luajit plugin/tools/update_pin.lua "$old" "$new"
sh plugin/tools/registry_gate.sh
sh plugin/tools/lint.sh
sh plugin/tools/test.sh
sh plugin/tools/bundle_check.sh
git add plugin/crier.version plugin/src/crier_obs/registry plugin/src/crier_obs/version.lua README.md docs
git -c user.name=github-actions\[bot\] -c user.email=github-actions\[bot\]@users.noreply.github.com commit -m "feat(crier-obs): mirror crier $new"
git push --set-upstream origin "$branch"
body=$(mktemp)
printf 'Mirror the generated crier %s configuration registry and pinned installer. Validated registry, lint, tests and bundled lifecycle smoke.\n' "$new" > "$body"
gh pr create --base main --head "$branch" --title "feat(crier-obs): mirror crier $new" --body-file "$body"
rm -f "$body"
