# Give a post a public URL

Instagram, Threads and TikTok's photo flow do not take uploaded bytes. They fetch the media from a public URL themselves, so a file on your computer is not enough. Staging gives the post that URL. Crier's [staging guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/staging/README.md) explains the modes.

`stage.mode` decides it, and it defaults to `none`. With `none` and one of those platforms ticked, crier refuses to run before rendering anything, and the post fails with exit 1. A tunnel mode on its own does nothing: it only applies when `stage.mode` is `server`.

Choose **Staging** in **Section**. Its guidance and its **Install ngrok**, **Install zrok**, **Staging guide** and **Tunnel guide** buttons come first, then `stage.mode`, then the `stage.server.tunnel.*` settings.

## ngrok

1. Install it from [ngrok](https://ngrok.com/downloads), sign up, and run `ngrok config add-authtoken <token>` once.
2. Set `stage.mode` to `server`.
3. Set `stage.server.tunnel.mode` to `ngrok`.

The free tier's interstitial page breaks Meta's fetcher, so use a paid plan or zrok.

## zrok

1. Install it from [zrok's getting started guide](https://docs.zrok.io/docs/getting-started/), run `zrok invite`, then `zrok enable <token>` once.
2. Set `stage.mode` to `server`.
3. Set `stage.server.tunnel.mode` to `zrok`.

zrok has no interstitial page.

For both, leave `stage.server.public-url` empty: crier refuses a public URL and a tunnel together. The tunnel program must be on the PATH crier sees, or named in full in `stage.server.tunnel.bin`. That PATH is OBS's own, extended with `~/.local/bin`, `~/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` and `/bin`, because OBS started from the Dock or the Start menu may not have your shell's PATH.

[Crier's tunnel guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/staging/tunnels.md) covers the arguments, URL discovery and custom tunnels.

## S3

S3 needs no tunnel.

1. Set `stage.mode` to `s3`.
2. Fill `stage.s3.endpoint`, `stage.s3.region` and `stage.s3.bucket`.
3. Paste `stage.s3.access-key` and `stage.s3.secret-key`, and press **Save credentials** for each.

`stage.s3.presign` is on by default. It hands the platform a signed URL, which works on a private bucket. With it off, the object must be public: set `stage.s3.acl` to `public-read` and `stage.s3.public-base-url` to whatever serves the bucket. The [S3 reference](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/stage/s3.md) lists the rest, and the [staging settings](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/stage/README.md) list every `stage.*` key.

## Check it

**Check setup** reports staging in its `stage` row: `Staging is not enabled` for `none`, otherwise crier's ping of the target, or `This staging mode has no credentials to check`. When `stage.server.tunnel.mode` is set, a `tunnel` row shows the tunnel program's path, or `Cannot find <program>`. It does not compare the two settings, so check that `stage.mode` is `server` yourself.
