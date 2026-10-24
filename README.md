# crier-obs

Stream announcements from OBS Studio. Add one Lua script, choose your platforms, and let [crier](https://github.com/yohimik/crier/tree/v1.1.1) render and publish your posts.

The dialog covers all 293 fixed crier settings and the 15 settings for each custom platform. Crier handles rendering, staging and publishing; the script supplies stream context and runs crier in the background.

## Install

1. Download [crier-obs.lua from v1.1.0-rc.0](https://github.com/yohimik/crier-obs/releases/download/v1.1.0-rc.0/crier-obs.lua). A newer candidate, when there is one, is at the top of the [releases page](https://github.com/yohimik/crier-obs/releases); take `crier-obs.lua` from it instead.
2. In OBS, open **Tools → Scripts**, press **+**, and choose that file.
3. Press **Install crier**. It runs crier's official installer for the pinned crier v1.1.1, which verifies the download against the digest GitHub publishes, and puts the binary in the plugin's state folder.
4. Tick your platforms in **Post to**. Choose **Platforms** in **Section**, select a platform in **Platform to configure**, fill its settings, and press **Save credentials** under each password field.
5. Set **Stream title** and **Stream URL**, then press **Check setup** and **Refresh results**. Try **Send a test post (dry run)** before going live.

This is the rc release line. The download names its tag because GitHub's `releases/latest` resolves stable releases only, and a release candidate is a prerelease. macOS, Windows and Linux use the same script. OBS must include LuaJIT support.

Stream start, stream end and hourly interval posts are enabled by default. You can also post when OBS quits while live, when recording starts or ends, and when a replay is saved. Replay posts publish the saved clip itself. Every trigger has its own caption, and every trigger uses the same selected platforms.

Credentials are stored in the macOS Keychain, Windows DPAPI, or Linux Secret Service. Linux can fall back to a private encrypted file store. They reach crier through environment variables. The OBS scene collection stores settings, but password fields are cleared before it is saved. See [credentials](docs/secrets.md) for the save and cache behavior.

[Setup](docs/setup.md) · [Triggers](docs/triggers.md) · [Data document](docs/data-document.md) · [Credentials](docs/secrets.md) · [Staging](docs/staging.md) · [Custom platforms](docs/custom-platforms.md) · [Advanced](docs/advanced.md) · [Troubleshooting](docs/troubleshooting.md) · [Development](docs/development.md) · [Releases](docs/release.md)

MIT licensed. Crier's own [configuration reference](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md) is pinned to the version this script mirrors.
