# Data available to templates

Each post gets a JSON document with the event, wall timestamps, monotonic uptime, current scene and profile, stream title, game, URL and the custom fields entered in OBS. Recording end and replay events include the corresponding saved path. Frontend collection is allow-listed; the streaming service key is never copied.

Use the fields in the bundled card or your own [crier template](https://github.com/yohimik/crier/blob/v1.1.1/docs/rendering/README.md). Caption expressions such as `{{ .title }}` and `{{ .uptime }}` use the same document. The document is written when a job is queued, so a later title, scene or settings change does not rewrite an earlier queued announcement.

With no data file selected, the context document becomes [render.data](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/render/README.md). If you choose a JSON file, the script merges context into it. User values win, including nested values; the script fills context fields that your document does not contain. Invalid JSON is reported and a context-only document is used.

A YAML data file is passed through untouched. No stream context is merged into YAML. Use JSON when you want both file data and OBS fields. Other file formats remain crier's responsibility.

Custom field entries use the first equals sign: `league=Friday finals`, `note=a=b`. Do not put credentials in custom data, captions, filenames or templates; those values are ordinary render inputs and are stored in run folders.
