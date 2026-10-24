# Add a custom destination

Choose **Custom platforms** in **Section**, then add names to **Custom platform names**. A name uses lower-case letters, digits and dashes, and starts with a letter or a digit. It cannot be one of the fourteen built-in platforms. Select a name in **Custom platform to configure** to edit its settings, and tick it in **Post to**.

Each name gets the 15 [custom platform settings](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/publish/custom.md), keyed `publish.custom.<name>.*`:

| Setting | Notes |
| --- | --- |
| `enabled` | the name's checkbox in **Post to** |
| `command`, `ping-command` | the publish command, and one that checks access without publishing |
| `caption` | overrides the trigger's caption for this destination |
| `kinds` | what the command accepts; crier's default is `image` only |
| `format`, `width`, `height`, `fit`, `fit-background`, `overlay`, `max-attachments` | the shape of what it receives |
| `needs-url`, `timeout` | whether crier stages the artifact and passes `CRIER_URL`, and how long the command may run |
| `env` | an editable list of `VAR=value` entries, the command's environment |

`VAR` is a letter or an underscore followed by letters, digits or underscores. Any other entry is skipped with the warning `Invalid custom environment entry for <name>`.

The command receives the artifact through [crier's custom command contract](https://github.com/yohimik/crier/blob/v1.1.1/docs/publishing/custom.md#the-contract). List `video` in `kinds` only when the command takes video: a clip post from **When a replay is saved** leaves out every custom destination whose `kinds` lacks it.

Removing a name removes its destination from later posts. Posts already queued keep the settings they were queued with. A renamed destination starts with fresh settings; copy the ones you want to keep.

With a base file, a custom destination defined only in that file is disabled for every post. Add its name here and tick it to post to it; the base file still supplies the settings you leave untouched.
