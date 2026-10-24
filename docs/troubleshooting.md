# Read a failed run

Start with the **crier** and **Last run** rows, then press **Check setup** and **Refresh results**. Every line the script writes to OBS's log starts with `crier-obs: `. A finished post logs its result at info level for exit 0, warning for exit 4 and error otherwise, followed by the last 20 lines of crier's stderr when there are any.

## Exit codes

| Exit | Last run reads | Meaning |
| --- | --- | --- |
| 0 | `Posted successfully` | crier finished; a dry run ends here too |
| 1 | `Invalid configuration` | a value is wrong or missing, a platform is not configured, or it needs a public URL and `stage.mode` is `none` |
| 2 | `Invalid command arguments` | crier rejected its command line |
| 3 | `Rendering failed` | the card or a caption template failed, such as a missing key |
| 4 | `Some platforms failed (<platforms>)` | some platforms took the post; one `<platform> did not take the post: <error>` line follows for each that did not |
| 5 | `Publishing failed` | no platform took the post |
| 6 | `Staging failed` | the media could not be given a public URL |
| 97 | `Run directory is missing` | the macOS and Linux wrapper could not enter the run folder |
| 126 | `crier is not executable` | followed by `On macOS, check the downloaded binary’s quarantine attribute.` |
| 127 | `crier was not found` | |

A timeout reads `crier exceeded the run timeout`, a signal `crier stopped by signal <n>`, and a Windows crash `crier crashed (NTSTATUS 0x<code>)`. Any other code reads `crier exited with code <n>`. Crier's [exit-code guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/exit-codes.md) and [logging guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/logging.md) explain its side.

## Log lines

The text after `crier-obs: `, with what to do about it.

| Line | Meaning |
| --- | --- |
| `crier-obs <version> for crier <pin>; state in <path>` | the script loaded; the path is the state folder |
| `crier is not installed; click Install crier` | discovery found no crier; press **Install crier** or set **crier path override** |
| `Configured crier path does not exist; click Install crier` | **crier path override** names a missing file |
| `crier <version> at <path> is older than <pin>; click Update crier` | logged once; press **Update crier** |
| `Install failed: <reason>` | the installer failed; the **crier** row shows the same text |
| `State directory is unavailable` | the state folder cannot be created or written; the **Run logs** row says why, and no post or check runs |
| `No platform is selected; post skipped` | tick a platform in **Post to** |
| `Replay post skipped: no saved clip path is available` | OBS reported no saved replay |
| `Clip post leaves out platforms that cannot post video: <platforms>` | those platforms are skipped for this clip |
| `Clip post skipped: none of the selected platforms can post video (<platforms>)` | tick a platform that takes video |
| `YAML render.data is passed through; stream context is skipped` | the card gets your YAML file and no OBS fields |
| `Cannot merge render.data; using stream context: <reason>` | your JSON data file is unreadable or not an object |
| `Post interval coalesced` | an interval post is already waiting |
| `Post <event> full` | the queue is full and only start and end posts may wait |
| `Dropped interval post: queue capacity reached` | a waiting interval post made room for another |
| `Dropped interval post: stream ended` | the stream ended before it ran |
| `Loaded while live; no start post for this stream` | the script loaded mid-stream |
| `Interval post armed: next post in <n> min` | the interval is counting |
| `Dry run planned <n> posts: <platforms>` | the dry run's result |
| `Check setup finished: <n> ok, <n> warnings, <n> failed` | press **Refresh results** to see the rows |
| `Base configuration changed after destination checks; post skipped` | the base file changed between its check and the post |
| `Enter a credential before saving <key>` | **Save credentials** was pressed with an empty field |
| `Credentials typed but not saved` | a typed value was dropped at unload |
| `Secret Service unavailable; credentials use the encrypted file store` | Linux fell back to the file store |
| `Credential store is locked; unlock it and try again` | unlock the keychain or Secret Service |

## Quitting, reloading and adopted posts

| Line | Meaning |
| --- | --- |
| `quit post spawned` | the quit post started in the background |
| `quit post skipped` | OBS closed or the script unloaded while offline, or with **When OBS quits while live** off |
| `quit post skipped: credentials are not ready` | the live session had not resolved its credentials yet |
| `quit post skipped: base configuration is not ready` | the live session's base file check had not finished, or **Base configuration file** now names another file |
| `Post skipped: OBS quit before it started (<event> post)` | a post was still waiting when OBS quit |
| `Detached <n> running posts; the next load adopts them` | posts kept running while the script unloaded |
| `Adopted <n> detached posts from an earlier load` | the next load found them |
| `Adopted <event> post finished with code <n>` | the **Last run** row reads `Last run finished with code <n>` |
| `Adopted <event> post stopped reporting; its result is unknown` | an adopted post ran far past its timeout |
| `Skipped <n> queued posts from an earlier OBS session` | backlog posts from an OBS that has exited, or older than ten minutes, were not published |

Reloading or removing the script while live counts as a quit; see [triggers](triggers.md#when-obs-quits).

With **Debug logging** on, `[debug]` lines at info level show scheduler decisions such as `scheduler: start post`, post states such as `start post: queued -> resolving_secrets`, and process details. Credential values never appear in them.

## Run folders

The state folder is `~/Library/Application Support/crier-obs` on macOS, `%LOCALAPPDATA%\crier-obs` on Windows, and `$XDG_STATE_HOME/crier-obs` or `~/.local/state/crier-obs` on Linux. The `CRIER_OBS_STATE_DIR` environment variable replaces it. The installed crier is in `bin`, the bundled card in `templates` and the credential files in `secrets`.

Each post and each **Check setup** gets a folder in `runs`, named `<unix time>-<OBS pid>-<n>`:

| File | Holds |
| --- | --- |
| `config.json` | the generated configuration, without a base file |
| `data.json` | the data document |
| `stdout`, `stderr` | crier's output, scrubbed |
| `status` | the exit code |
| `pid` | crier's process id |
| `journal.json` | the post's state, for adoption after an unload |
| `preview.png` | the dry run's render |
| `queued.json` | the post's snapshot while it waits in the backlog |

After each post and at load, finished folders past **Maximum run folders** or older than **Keep run folders for days** are removed.

## Common causes

No platform ticked means no post. Missing credentials usually produce exit 1. Instagram, Threads and TikTok's photo flow with `stage.mode` at `none` also produce exit 1; see [staging](staging.md). Use a dry run and [the platform guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/publishing/README.md) to narrow it down.

If a downloaded macOS binary cannot run, quarantine may be blocking it, and the post fails with exit 126 and the quarantine hint. **Install crier** removes the attribute from the crier it installs. A crier named in **crier path override** may need approval in System Settings. Files in Documents or Desktop can also prompt for macOS access.

A locked login Keychain can show a system unlock dialog. On Linux, an installed `secret-tool` does not guarantee that Secret Service is running. Values stored in a backend that is unavailable stay unavailable until it works again; save them again or forget them deliberately if you are changing stores.

A scene collection switch or an unload stops a running installer, and the **crier** row reads `Installation cancelled because the script unloaded`; press **Install crier** again.

A detached post may finish after a scene collection switch or after OBS closes. The next load adopts it and reports its code. Crier inherits only its standard streams, so a background post does not keep OBS's websocket port 4455 open. If one does, report the OS, the OBS version and the scrubbed run folder.

A Flatpak host bridge needs a current `flatpak-spawn` with `--env-fd` support and a current host portal; keep the state folder and render inputs under the shared home directory. See [advanced](advanced.md#flatpak-and-snap).
