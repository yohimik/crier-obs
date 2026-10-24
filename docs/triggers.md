# Choose when to post

| Trigger | Default | Caption |
| --- | --- | --- |
| **When streaming starts** | on | `🔴 Live now: {{ .title }}` |
| **When streaming ends** | on | `Thanks for watching! {{ .title }}` |
| **Every N minutes while live** | on, 60 minutes | `Still live ({{ .uptime }}): {{ .title }}` |
| **When OBS quits while live** | off | `Something went wrong on our side. Don't leave, we are coming back!` |
| **When recording starts** | off | `Recording started: {{ .title }}` |
| **When recording ends** | off | `Recording done: {{ .title }}` |
| **When a replay is saved** | off | `Clip: {{ .title }}`, posted with the saved clip |

Each trigger is a checkbox followed by its own caption field, such as **When streaming starts: caption**. The platforms ticked in **Post to** apply to every trigger.

Captions are crier [caption templates](https://github.com/yohimik/crier/blob/v1.1.1/docs/templates/captions.md). They read the [data document](data-document.md) and crier's own `{{ .Platform }}`. A key that is not there is an error: crier exits 3 and nothing is posted. A platform's own caption setting, such as `publish.discord.caption`, overrides the trigger's caption on that platform.

**Post now** publishes with **Manual caption**, `🔴 Live now: {{ .title }}` by default, and the event `manual`. **Send a test post (dry run)** uses the same caption with the event `test`. It runs crier with `--publish-dry-run`, writes `preview.png` into the run folder and posts nothing.

## Every N minutes

**Interval in minutes** takes 1 to 1440 and defaults to 60. The first interval post is due that long after the stream starts. Interval time is monotonic: a sleep or a delayed OBS timer produces at most one interval post, never a backlog. Changing the interval, or turning the trigger on during a stream, counts the next post from that moment.

At most one interval post waits in the queue. An end event takes precedence over an interval due at the same time, and the end of a stream drops interval posts that are still waiting.

Loading the script while already live starts a session whose start is estimated from OBS's frame count. The interval is armed from that moment, and no start post is sent for that stream.

## When OBS quits

OBS does not deliver a stream-stopped event when it closes while streaming. The quit trigger fires once per load instead, from OBS's scripting shutdown, or from a script unload that came with no shutdown and no scene collection switch. A macOS application quit takes the second path.

It starts one background post from the credentials already resolved for the live session, and does not wait for it. If those credentials are not ready, it logs a skip instead of starting a keyring operation during shutdown. With a **Base configuration file**, the destination check for that exact file must have finished during the stream; a changed or unchecked file skips the quit post. Posts still waiting in the queue are skipped, so a stale "Live now" never posts at the next launch.

OBS gives a script no signal that tells a reload or a removal apart from a quit. **Reloading or removing the script while live sends the quit post.** After a reload the stream carries on without a start post, as above. Untick **When OBS quits while live** before reloading during a stream.

A scene collection switch is not a quit. If OBS is killed without a shutdown callback, no script can send a quit post.

## Recordings and replays

The recording triggers work while offline. Their `uptime` and `started_at` describe the recording. `recording_path` is set on `recording_end` only.

**When a replay is saved** publishes the clip OBS reports as is, through crier's [publish-only flow](https://github.com/yohimik/crier/blob/v1.1.1/docs/publishing/flows.md#publish-only) (`--publish-input <clip>`). The card is not rendered, and crier's own video rendering is turned off for that post. Platforms that cannot post video are left out with a warning: `boosty`, and every custom platform whose `kinds` does not list `video`. If none remain, the post is skipped. The destinations left must still accept the clip's format and size; crier reports the ones that refuse it. A replay saved during another post waits in the queue.

## The queue

Posts run one at a time, and up to five wait in memory. When the queue is full, a waiting interval post makes room. Failing that, a start or end post goes to a backlog on disk, `queued.json` in its run folder, and runs once the queue empties. Any other post is refused with a warning. While the backlog holds a post, new start and end posts join it and other posts are refused.

The backlog also carries start and end posts across a scene collection switch. The next load in the same OBS process restores them in order, within ten minutes. A post left by an OBS that has since exited, or older than that, is journaled as skipped and never published.

A waiting post keeps the data document and the invocation it was queued with. It holds no credentials; they are resolved when the post starts. A backlog write failure is logged.
