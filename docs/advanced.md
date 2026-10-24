# Use a base configuration

Without a base file, every post writes a generated `config.json` into its run folder and runs crier with `--config` pointing at it. It carries every setting whose dialog value differs from crier's default, so the script's own defaults travel too: the bundled card, 1080 × 1080 PNG and hermetic fonts. The [crier reference](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md) explains every setting.

Pick a YAML, JSON or TOML file in **Base configuration file** under **Advanced** to start from your own configuration. Crier then runs with `--config <base>` and one `--set key=value` per override. For a setting you have not changed in the dialog, the base file wins. A value you change stays explicit, even when you change it back to crier's default. OBS's Defaults button resets the dialog settings. See [crier's three layers](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md) for how a file and `--set` combine.

Some settings are always sent, base file or not:

| Setting | Value |
| --- | --- |
| `publish.<platform>.enabled`, `publish.custom.<name>.enabled` | the **Post to** ticks; unticked is `false` |
| `publish.caption` | the trigger's caption |
| `render.data` | the post's [data document](data-document.md) |
| `publish.input`, `render.video.enabled` | for a clip post, the clip and `false` |

`--log-level` follows `log.level`; with a base file it is sent only when you have changed it.

## Destinations in the base file

Before a post, the script runs `crier config --json --all` on the base file and disables every custom destination that the file defines but the dialog does not list. An unseen destination cannot publish behind an unticked dialog. A fingerprint of the file is taken for that check. If the file changes before the post starts, the post is skipped with `Base configuration changed after destination checks; post skipped`.

A live session checks the base file when the stream starts. The quit post uses that result and skips when it is missing or was taken for another file.

## Lists and the command line

Lists are JSON arrays in generated mode. With a base file they travel as one comma-separated `--set` value, so a comma inside an item cannot be represented; the post logs `List <key> contains a comma, which crier splits in --set values`. Move that list into your base file. A command line longer than the limit fails with `Configuration exceeds the command-line limit; use generated configuration mode`.

`--set` arguments may be visible to process inspection tools such as `ps`. Credentials never travel as arguments; they stay in the environment.

## Paths

Paths in a base file resolve by [crier's rules](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md#where-relative-paths-point). With a base file, crier runs from the base file's folder, and relative dialog paths are made absolute against it. Without one, they are made absolute against the state folder.

**crier path override** takes precedence over the copy in the state folder's `bin` and over the PATH search. OBS launched from the Dock or the Start menu may have a different PATH than a terminal, so discovery also searches `~/.local/bin`, `~/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` and `/bin`, or WinGet's `Links` folder on Windows.

## Flatpak and Snap

Linux Flatpak or Snap packages can isolate OBS from host tools and Secret Service. The script logs the restriction at load and reports it in **Check setup**.

In Flatpak, crier runs through `flatpak-spawn --host`. The environment goes through a separate descriptor (`--env-fd`), so credentials are never put in `--env` arguments. The inherited host environment is cleared (`--clear-env`), and the host command is cleaned up when the helper exits (`--watch-bus`). This needs a current Flatpak host portal, a helper that supports `--env-fd`, and configuration, templates, media and the state folder under the shared home directory. Very old portals that silently ignore `--watch-bus` are unsupported. A path that cannot be mapped fails with an explicit error. An older helper may reject `--env-fd`; update it or run a native OBS package. See the [Flatpak helper source](https://github.com/flatpak/flatpak-xdg-utils/blob/main/src/flatpak-spawn.c) for its environment descriptor contract.

## Run settings

| Setting | Default |
| --- | --- |
| **Run timeout in seconds** | 900 |
| **Keep run folders for days** | 7 |
| **Maximum run folders** | 50 |

A post that runs past its timeout is stopped. On macOS and Linux, crier gets a terminate request first, then a kill 10 seconds later. On Windows, the post's job object is terminated at once, with crier and every process it started.

**Debug logging** adds state transitions, scheduler decisions and process metadata to OBS's log, as `[debug]` lines at info level. Without it, those lines are debug level, which OBS drops unless it runs with `--verbose`. It never records credential values.
