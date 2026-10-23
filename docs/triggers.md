# Choose when to post

| Trigger | Default | Content |
| --- | --- | --- |
| Stream starts | on | “🔴 Live now: {{ .title }}” |
| Stream ends | on | “Thanks for watching! {{ .title }}” |
| Every N minutes while live | on, 60 minutes | “Still live ({{ .uptime }}): {{ .title }}” |
| OBS quits while live | off | “Something went wrong on our side. Don't leave, we are coming back!” |
| Recording starts | off | “Recording started: {{ .title }}” |
| Recording ends | off | “Recording done: {{ .title }}” |
| Replay saved | off | “Clip: {{ .title }}” and the saved clip |

Each row has its own enable box and caption. Captions use [crier's template data](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/publish/README.md) and the [OBS data document](data-document.md). The selected platforms apply to every row.

Interval time is monotonic, from 1 to 1440 minutes. A sleep or delayed OBS timer produces at most one interval post; it does not send a backlog. Loading the script while already live starts an estimated session and arms the interval without announcing a second start. An end event takes precedence over an interval due at the same time.

OBS does not deliver a normal stream-stopped event when it closes while streaming. The quit trigger uses scripting shutdown instead. It starts one background post from credentials already resolved for the live session. If those credentials are not ready, it logs a skip instead of starting a keyring operation during shutdown. With an advanced base file, destination checks must have completed for that exact file; a changed or unchecked base file skips the quit post. An ordinary scene collection switch does not send a quit post. If OBS is killed without a shutdown callback, no script can send one.

Recording triggers work while offline. The end document includes the last recording path. Replay saved publishes the exact path OBS reports using [crier's existing-file input](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/cli.md). Your destination must accept that video's format and size; crier reports destinations that reject video. A replay arriving during another post is queued.

Posts run sequentially. The memory queue holds up to five waiting jobs and coalesces pending interval posts. If critical stream start, end or quit work overflows that queue, it is preserved in a durable backlog and restored in order on the next tick or script load. Queued records contain the original context and invocation snapshot; credentials are resolved when the job starts. Other overflow posts can be dropped with a warning. A backlog write failure is reported explicitly.
