# Data available to templates

Each post gets one JSON document. The card and every caption read it. The script builds it when the post is queued, so a later title, scene or settings change does not rewrite an announcement that is still waiting. It is saved as `data.json` in the post's run folder and reaches crier as [`render.data`](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/render/README.md).

## The fields

Every field is present in every document. A field that does not apply holds an empty string, `0` or `false`.

| Field | Type | Value | Example caption |
| --- | --- | --- | --- |
| `event` | string | what triggered the post: `start`, `end`, `interval`, `quit`, `recording_start`, `recording_end`, `replay`, `manual` (**Post now**) or `test` (**Send a test post (dry run)**) | `{{ if eq .event "end" }}Thanks for watching!{{ else }}Live now{{ end }}` |
| `now` | string | local time with its UTC offset, such as `2026-10-24T21:15:00+0200` | `Posted at {{ .now }}` |
| `now_utc` | string | the same moment in UTC, such as `2026-10-24T19:15:00Z` | `Posted at {{ .now_utc }}` |
| `started_at` | string | when the stream started, in UTC; on recording posts, when the recording started; empty when offline | `Live since {{ .started_at }}` |
| `started_at_estimated` | bool | `true` when the script loaded mid-stream and estimated the start from OBS's frame count and frame rate | `{{ if .started_at_estimated }}About {{ end }}{{ .uptime }} in` |
| `uptime_seconds` | number | whole seconds since `started_at`; `0` when offline | `{{ .uptime_seconds }} seconds live` |
| `uptime` | string | the same as `HH:MM:SS`; `00:00:00` when offline | `Still live ({{ .uptime }})` |
| `interval_index` | number | interval posts that came due in this stream so far: `1` on the first interval post, `0` on the start post and offline | `Check-in {{ .interval_index }}: {{ .title }}` |
| `scene` | string | the current scene | `Now on screen: {{ .scene }}` |
| `profile` | string | the current OBS profile | `Streaming with the {{ .profile }} profile` |
| `scene_collection` | string | the current scene collection | `Tonight's set: {{ .scene_collection }}` |
| `service` | string | the service named in OBS's stream settings, such as `Twitch` | `Live on {{ .service }}` |
| `server` | string | the ingest server named in the same settings | `Ingest: {{ .server }}` |
| `title` | string | **Stream title** | `🔴 Live now: {{ .title }}` |
| `game` | string | **Game** | `Playing {{ .game }}` |
| `url` | string | **Stream URL** | `Watch at {{ .url }}` |
| `fields` | object | **Custom data fields (key=value)**, one key per entry | `{{ .fields.league }} tonight` |
| `platforms` | list | the platforms ticked in **Post to**, sorted by name | `Also on {{ join ", " .platforms }}` |
| `recording_path` | string | the saved recording, on `recording_end` only | `Recording done: {{ .recording_path }}` |
| `replay_path` | string | the saved clip, on `replay` only | `Clip saved as {{ .replay_path }}` |
| `obs_version` | string | OBS's version | `Made with OBS {{ .obs_version }}` |
| `plugin_version` | string | this script's version | `Posted by crier-obs {{ .plugin_version }}` |

Crier adds `{{ .Platform }}` to captions, the name of the platform being posted to. It also adds the pagination fields its [captions guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/templates/captions.md) lists.

A recording post describes the recording: its `started_at`, `uptime` and `started_at_estimated` belong to the recording, not the stream, and `interval_index` is 0. A script loaded mid-recording counts the recording from the load and marks it estimated. Every other post describes the stream. One sent while offline, such as **Post now** between streams, carries an empty `started_at` and an uptime of 0.

The script reads the service and server by name only. The stream key is never copied.

Interval posts use the scene, profile and collection that OBS last reported through a frontend event, not a fresh read.

## An example

An interval post one hour into a stream:

```json
{
  "event": "interval",
  "now": "2026-10-24T21:15:00+0200",
  "now_utc": "2026-10-24T19:15:00Z",
  "started_at": "2026-10-24T18:15:00Z",
  "started_at_estimated": false,
  "uptime_seconds": 3600,
  "uptime": "01:00:00",
  "interval_index": 1,
  "scene": "Gameplay",
  "profile": "Untitled",
  "scene_collection": "Main",
  "service": "Twitch",
  "server": "auto",
  "title": "Road to the finals",
  "game": "Chess",
  "url": "https://twitch.tv/example",
  "fields": {"league": "Friday league"},
  "platforms": ["discord", "telegram"],
  "recording_path": "",
  "replay_path": "",
  "obs_version": "32.0.2",
  "plugin_version": "1.1.0-rc.0"
}
```

## Templates and captions

The bundled card is `templates/live.html` in the state folder. It shows `event`, `title`, `game`, `uptime` and `url`. The script writes it only when it is missing, so your edits to it stay. To use your own card, pick it in `render.template` under **Render**. Crier's [template guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/templates/README.md) explains the syntax and the functions, such as `join` and `default`.

Captions are crier [caption templates](https://github.com/yohimik/crier/blob/v1.1.1/docs/templates/captions.md) over the same document. In the card, a key that is not there prints as nothing. In a caption, it is an error: crier exits 3 and nothing is posted. The fields above are always there. A custom field is there only when you enter it, so `{{ .fields.league }}` with no `league=` entry stops the post.

## Your own data file

With `render.data` empty, the document above is the whole data document.

| `render.data` | What crier reads |
| --- | --- |
| empty | the document above |
| a `.json` file | your file merged with the document: your values win, objects merge key by key, lists are replaced whole |
| a `.yaml` or `.yml` file | your file untouched, with no stream context |
| anything else | that value, passed to crier as it is |

If the JSON file cannot be read, or its top level is not an object, the post logs `Cannot merge render.data; using stream context: …` and uses the document alone. A YAML file logs `YAML render.data is passed through; stream context is skipped`. Use JSON when you want both your data and the OBS fields.

A relative path is read from the state folder, or from the base file's folder when a **Base configuration file** is set.

## Custom fields

Each entry in **Custom data fields (key=value)** splits at the first equals sign: `league=Friday league` gives `league`, and `note=a=b` gives `note` the value `a=b`. Spaces are kept as typed. An entry with no equals sign, or nothing before it, is skipped. A repeated key keeps the last value.

Do not put credentials in custom data, captions, filenames or templates. Those are ordinary render inputs, and they are stored in run folders.
