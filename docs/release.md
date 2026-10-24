# Release a candidate

Releases must go through the **release** GitHub Actions workflow with [dispat](https://dispat.dev). Do not upload or tag from a local shell, even to repair a failed run. The whole configuration is in [`dispat.yaml`](../dispat.yaml).

```sh
dispat status     # what would be released, and why
```

## Running one

The **release** workflow uses `workflow_dispatch`. It has one concurrency group and never cancels a running release. Every job that runs dispat sets it up through `yohimik/dispat@v1` pinned to version 1.10.0, as `tests.yml` does, so dispat changes behaviour only when that pin is bumped on purpose. It has four jobs:

1. **plan**: runs `dispat status --require-release`. Exit 3 means nothing is releasable since the last tag: the run logs a notice, skips every later job and ends green. Any other nonzero code fails the run.
2. **tests**: runs `tests.yml` against the commit about to be tagged.
3. **release**: installs LuaJIT and runs `dispat --log-format json` with `contents: write`. This one command handles the version, the build, the changelog, the commit, the tag and the GitHub release.
4. **install**: runs on Ubuntu, macOS and Windows. It downloads `crier-obs.lua` from the new release, deletes `plugin/src`, compiles the asset with `luajit -bl` and runs `tools/smoke.lua` on it. With `src/` gone, the asset cannot borrow a module from the checkout. Windows builds the Go fake crier first. A release is not finished until its asset passes there.

It needs no secrets beyond the automatic `GITHUB_TOKEN`.

## The dispat flow

The package `crier-obs` lives in `plugin`, with `autoVersion: {manifests: none}`: no manifest carries the version. `version.lua` keeps `0.0.0-dev` in the source, and only the built asset is stamped. Its flow:

| Stage | Script | Does |
| --- | --- | --- |
| build | `sh tools/build.sh` | bundles and stamps `dist/crier-obs.lua` |
| publish | `dispat changelog`, `dispat commit --tag --push`, `dispat github` | the changelog, the release commit and tag as `github-actions[bot]`, the GitHub release |
| announce | inline in `dispat.yaml` | writes `released=true` and `version=<version>` to `GITHUB_OUTPUT` |

The **release** job exports the announce stage's two values. The **install** job runs only when `released` is `true`, and downloads tag `v<version>`.

`tools/build.sh` requires `DISPAT_NEW_VERSION`. It bundles with that version in the header line and in the version module, then runs the smoke with `--version` and `--pin`, which also checks the crier pin against the registry metadata. It fails unless the header reads `-- crier-obs <version> |`, the embedded `VERSION` equals `DISPAT_NEW_VERSION`, and no `0.0.0-dev` stamp remains. It then writes `DISPAT_EXPORT_GITHUB` to `DISPAT_OUTPUT`, which attaches the file to the GitHub release. The asset is always named `crier-obs.lua`.

Each GitHub release ends with the footer from `dispat.yaml`: how to install the script, and a link to this repository's docs at the release tag.

## Commits

Make commits conventional and scoped to the package, such as `fix(crier-obs): scrub a failed response`. `commitErrors: error` refuses a release when a commit cannot be parsed. Check a message before you commit:

```sh
dispat diagnostics --config dispat.yaml '<message>'
```

## The rc train

The baseline is `initials: {crier-obs: 1.0.0}`, and `parser.allowedChannels` admits only `rc`. The first feature commit, `feat(crier-obs)%rc: add the OBS announcement client`, puts the package on the rc channel, with the directive before the colon. `dispat status` plans `1.0.0 -> 1.1.0-rc.0` with `channel="stable -> rc"`. Do not put `!` in ordinary feature commits.

Later commits ride the same train: a fix or a feature after `1.1.0-rc.0` makes `1.1.0-rc.1`, and so on. Each candidate gets its own changelog entry and a GitHub release that dispat flags as a prerelease.

A transition graduates the train:

```
release(crier-obs)%rc>stable: promote the first release
```

That releases `1.1.0`. The `%rc>stable` form matches the baseline channel, so it is safe to write again after the package has graduated.

Before dispatching, read `dispat status` and confirm the package, the version and the channel.

## Install links during the candidate period

GitHub's `releases/latest` resolves stable releases only, so it skips every candidate. The README therefore links the first candidate by its tag, and points at the [releases page](https://github.com/yohimik/crier-obs/releases) for newer ones; a new candidate needs no README edit. At graduation, change the README's download link to `https://github.com/yohimik/crier-obs/releases/latest/download/crier-obs.lua` in the graduation commit.

Upstream [crier installation](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/install.md) is pinned separately, through `plugin/crier.version`.

## When something fails

A release is not atomic. If publication partly succeeds, inspect the remote tag and the release before retrying through the workflow. Keep publication credentials in Actions.
