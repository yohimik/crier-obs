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
branch="crier-sync/v$new"
if gh pr list --head "$branch" --json number --jq '.[0].number' | grep '[0-9]' >/dev/null; then exit 0; fi
git switch -c "$branch"
printf '%s\n' "$new" > plugin/crier.version
# Documentation and install version always move with the registry pin.
mkdir -p "plugin/.cache/v$new"
git clone --quiet --depth 1 --branch "v$new" https://github.com/yohimik/crier.git "plugin/.cache/v$new/source"
(cd plugin && luajit tools/gen_registry.lua ".cache/v$new/source")
luajit plugin/tools/update_pin.lua "$old" "$new"
# A pull request opened with GITHUB_TOKEN starts no workflow, so the gates the bump can affect run here.
sh plugin/tools/registry_gate.sh
sh plugin/tools/lint.sh
sh plugin/tools/test.sh
sh plugin/tools/bundle_check.sh
title="feat(crier-obs): follow crier v$new"
git add plugin/crier.version plugin/src/crier_obs/registry plugin/src/crier_obs/version.lua README.md docs
git -c user.name=github-actions\[bot\] -c user.email=github-actions\[bot\]@users.noreply.github.com commit -m "$title"
# The branch belongs to this job: a branch left by a closed pull request is replaced, not a reason to stop.
git push --force-with-lease --set-upstream origin "$branch"
body=$(mktemp)
cat > "$body" <<EOF
Follow crier v$new: the generated configuration registry, the pinned installer and the documentation links.

The sync job ran the registry, lint, tests and bundle-check gates on Linux, then dispatched tests.yml on this branch for the full matrix, because a pull request opened with GITHUB_TOKEN starts no workflow of its own.
EOF
gh pr create --base main --head "$branch" --title "$title" --body-file "$body"
rm -f "$body"
gh workflow run tests.yml --ref "$branch"
