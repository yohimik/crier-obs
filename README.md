# crier-obs

Stream announcements from OBS Studio. Add one Lua script, choose your platforms, and let [crier](https://github.com/yohimik/crier/tree/v1.1.1) render and publish your posts.

The dialog covers all 293 fixed crier settings and the 15 settings for each custom platform. Crier handles rendering, staging and publishing; the script supplies stream context and runs crier in the background.

## Install

1. Download [crier-obs.lua from v1.1.0-rc.0](https://github.com/yohimik/crier-obs/releases/download/v1.1.0-rc.0/crier-obs.lua).
2. In OBS, open **Tools → Scripts**, press **+**, and choose that file.
3. Press **Install crier**. The installer verifies the pinned crier v1.1.1 binary and puts it in the plugin's state folder.
4. Tick the platforms you want. Select a platform in **Platform to configure**, fill its settings, and press **Save credentials** for each password field.
5. Set your title and stream URL, then press **Check setup** and **Refresh results**. Try **Send a test post (dry run)** before going live.

This is the rc release line. The download names its tag because GitHub's `releases/latest` resolves stable releases only. macOS, Windows and Linux use the same script. OBS must include LuaJIT support. Linux requires glibc 2.34 or newer for atomic child descriptor isolation.

Stream start, stream end and hourly interval posts are enabled by default. You can also enable a post when OBS quits while live, when recording starts or ends, and when a replay is saved. Replay posts publish the saved clip itself. Every trigger has its own caption; every trigger uses the same selected platforms.

Credentials are stored in macOS Keychain, Windows DPAPI, or Linux Secret Service. Linux can fall back to a private encrypted file store. They reach crier through environment variables. The OBS scene collection stores settings, but password fields are cleared before it is saved. See [credentials](docs/secrets.md) for the save and cache behavior.

[Setup](docs/setup.md) · [Triggers](docs/triggers.md) · [Data document](docs/data-document.md) · [Staging](docs/staging.md) · [Troubleshooting](docs/troubleshooting.md) · [Development](docs/development.md)

MIT licensed. Crier's own [configuration reference](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md) is pinned to the version this script mirrors.
