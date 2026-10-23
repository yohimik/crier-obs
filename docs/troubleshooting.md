# Read a failed run

Start with **Status**, then **Check setup → Refresh results**. OBS's script log lines start with `crier-obs:`. The status row gives the latest result; each run folder contains the generated configuration, data document, output, stderr, status and pid journal. A dry run also asks crier to write `preview.png`. Retention removes old folders according to the configured age and count.

State folders are `~/Library/Application Support/crier-obs` on macOS, `%LOCALAPPDATA%\crier-obs` on Windows, and `$XDG_STATE_HOME/crier-obs` or `~/.local/state/crier-obs` on Linux. The private executable is in `bin`; jobs are in `runs`.

| Exit | Meaning |
| --- | --- |
| 0 | completed |
| 1 | configuration |
| 2 | command usage |
| 3 | rendering |
| 4 | some destinations failed |
| 5 | publishing failed |
| 6 | staging failed |
| 97 | run directory unavailable |
| 126 / 127 | executable cannot run / cannot be found |

Crier's [exit-code guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/exit-codes.md) and [logging guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/logging.md) explain its side. A signal, timeout or Windows crash is reported separately. Inspect the scrubbed stderr tail for the cause.

If a downloaded macOS binary cannot run, quarantine may be blocking it. The plugin's installer clears the attribute on its own installed executable. An explicit executable may need approval in System Settings. Files in Documents or Desktop can also prompt for macOS access.

A locked login Keychain can show a system unlock dialog. Linux `secret-tool` being installed does not guarantee Secret Service is available. Stored credentials in an unavailable backend remain unavailable until that backend works; resave or forget them deliberately if changing stores.

A detached post may finish after a scene collection switch or OBS close. The next load adopts journaled jobs and reports their completion. Critical stream posts waiting in the durable backlog are restored in order; their saved snapshot keeps the original title, caption and destination choices. Children inherit only their standard streams, so a background post should not keep OBS's websocket port 4455 open. If it does, report the OS, OBS version and the scrubbed run journal.

No destination selected means no post. Missing credentials usually produce crier exit 1. A replay post can fail for a destination that does not accept video. Use a dry run and [the platform guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/publishing/README.md) to narrow it down.

On Linux, a descriptor-hygiene error can mean the libc lacks atomic close-from spawning. Use glibc 2.34 or newer. A Flatpak host bridge additionally needs a current `flatpak-spawn` with `--env-fd` support and a current host portal; keep the state folder and render inputs under the shared home directory.

Changing scene collections or unloading the script cancels an in-progress installer. Reopen the dialog and retry Install if needed; the next version check discovers a completed installation.
