# Set up your first post

Add `crier-obs.lua` through **Tools → Scripts → +**. The dialog is one long list. Its top part is always visible; the **Section** choice below it decides which crier settings show.

## The status rows

Each row shows its label on the left and its state on the right.

| Row | Shows |
| --- | --- |
| **crier** | `crier <version> at <path>`, `crier is not installed`, or `crier <version> at <path> (older than <pin>)`; while the installer runs, `Installing crier <pin>…`, `Checking installed crier…` or `Install failed: <reason>` |
| **Credential store** | `macOS Keychain`, `Windows DPAPI (current user)`, `Secret Service` or `Encrypted credential file (Secret Service unavailable)` |
| **Last run** | `No posts yet`, then the latest result, such as `Posted successfully` |
| **Run logs** | the `runs` folder in the state folder |

Press **Install crier** when crier is missing. The button reads **Update crier** when the discovered crier is older than the pinned crier v1.1.1. It runs crier's official installer for that version, which verifies the download against the digest GitHub publishes, and installs into the state folder's `bin`. **Install crier documentation** opens crier's [installing guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/install.md). A **crier path override** in **Advanced** takes precedence over discovery.

## Posting

The seven triggers come next, each a checkbox and its caption. [Triggers](triggers.md) lists them with their defaults.

**Post to** holds one checkbox per platform, then one per custom platform. The choices apply to every trigger. Every unticked destination is explicitly disabled, including destinations enabled in a base file.

Enter **Stream title**, **Game** and **Stream URL**. Add optional entries to **Custom data fields (key=value)**. They reach the card and the captions through the [data document](data-document.md).

| Button | What it does |
| --- | --- |
| **Check setup** | checks the executable, the credential store, staging, ffmpeg when video is on, the tunnel program when a tunnel mode is set, and each ticked platform's access |
| **Refresh results** | redraws the dialog with the latest status and results |
| **Send a test post (dry run)** | renders with **Manual caption** and posts nothing; the run folder gets `preview.png` |
| **Post now** | publishes with **Manual caption** |

The results of **Check setup** appear under **Post now**, one row per check. Each row is named after its target, such as `crier`, `keyring`, `stage`, `ffmpeg`, `tunnel` or a platform. Its state starts with ✓ (passed), ✗ (failed) or ! (a warning), followed by the account, the message and the time taken. A `setup` row reads `checking…` while the checks run; press **Refresh results** to see them finish.

## Sections

| Section | Holds |
| --- | --- |
| **Platforms** | **Platform to configure**, then that platform's `publish.<platform>.*` settings and its **How to get these values** link to crier's guide for it; the shared `publish.*` settings follow |
| **Custom platforms** | **Custom platform names**, **Custom platform to configure**, that platform's settings and **Custom platform guide**; see [custom platforms](custom-platforms.md) |
| **Render** | `render.*`, crier's [rendering settings](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/render/README.md) |
| **Video** | `render.video.*`, crier's [video settings](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/render/video.md) |
| **Staging** | the public URL guidance, then `stage.mode`, the `stage.server.tunnel.*` settings and the rest of `stage.*`; see [staging](staging.md) |
| **Advanced** | **Base configuration file**, **crier path override**, **Credential set**, **Forget all credentials in this credential set**, **Debug logging**, **Run timeout in seconds**, **Keep run folders for days**, **Maximum run folders**, then `http.*` and `log.*`; see [advanced](advanced.md) |

A crier setting is labelled with its key, such as `publish.telegram.chat-id`, and its tooltip is crier's description. [Crier's configuration reference](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md) has every key.

## Your first platform

1. Tick the platform in **Post to**.
2. Choose **Platforms** in **Section**, then the platform in **Platform to configure**.
3. Fill the settings that **How to get these values** describes. It opens that platform's [crier guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/publishing/README.md).
4. For every password field, paste the value and press **Save credentials** under it. Typing alone does not commit it. Its **Credential status** row reads `saving…`, then `stored ✓` or `not stored: <reason>`. See [credentials](secrets.md).
5. Press **Check setup**, then **Refresh results**.
6. Press **Send a test post (dry run)**, and open the run folder's `preview.png`.

Instagram, Threads and TikTok's photo flow also need a public URL; set up [staging](staging.md) first.

## Defaults

The card is the bundled template at 1080 × 1080, PNG, with hermetic fonts: `render.width` and `render.height` are 1080, `render.format` is `png` and `render.hermetic-fonts` is on. Crier's own default height is 1920. Without a base file, every default the script sets reaches crier; with one, the base file wins for settings you have not changed.

OBS settings belong to the scene collection. Credentials belong to the named **Credential set**, `default` initially. Two collections that select the same set share the credentials. Choose a separate set for a different account.
