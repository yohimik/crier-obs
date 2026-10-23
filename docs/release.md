# Release a candidate

Release only through the **release** GitHub Actions workflow. It plans with `dispat status --require-release`, runs the required gates, builds the stamped script, publishes the changelog, commit, tag and GitHub release, and downloads the asset for a smoke test on macOS, Linux and Windows. The artifact is always named `crier-obs.lua`.

The baseline is `initials: {crier-obs: 1.0.0}`. The first feature commit is `feat(crier-obs)%rc: …`, with the channel directive before the colon. It plans `1.1.0-rc.0`. Later candidates ride the same rc train. `release(crier-obs)%rc>stable: …` graduates it to `1.1.0`. Do not put `!` in ordinary initial feature commits.

Before dispatch, inspect `dispat status` and confirm the expected package, version and channel. `dispat diagnostics --config dispat.yaml '<message>'` validates a source message. The release workflow has one concurrency group and never cancels a running release. Keep publication credentials in Actions.

The build requires `DISPAT_NEW_VERSION`, embeds it in the header and version module, and rejects any remaining development stamp. Its smoke also checks the crier pin against the registry metadata. `DISPAT_EXPORT_GITHUB` is written through `DISPAT_OUTPUT` to opt the artifact into the GitHub release. The announce stage exports `released` and `version` for installation verification.

During the candidate period, installation documentation links to the exact candidate tag because GitHub's latest-release endpoint selects stable versions. Release notes link to this repository's docs at the release tag. Upstream [crier installation](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/install.md) stays pinned independently through `plugin/crier.version`.

A release is not atomic. If publication partially succeeds, inspect the remote tag and release before retrying through the workflow. Do not upload or tag from a local agent shell to repair a failed pipeline.
