# Give a post a public URL

Some destinations fetch media from a public URL. Instagram is one: a path on your computer is not enough. Select **Staging** and use [crier's staging settings](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/stage/README.md). For a local stage server, choose a tunnel mode; alternatively upload to S3.

**ngrok:** install from [ngrok](https://ngrok.com/downloads), sign up, and run `ngrok config add-authtoken <token>` once. Set the tunnel mode to ngrok. The free tier's interstitial page breaks Meta's fetcher, so use a suitable paid plan or choose zrok.

**zrok:** install from [zrok's getting started guide](https://docs.zrok.io/docs/getting-started/), run `zrok invite`, then `zrok enable <token>` once. Set the tunnel mode to zrok. Ensure the executable is visible in OBS's PATH.

**S3:** configure the bucket, endpoint and public URL using the [S3 reference](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/stage/s3.md). Save the access key and secret key with the credential buttons. This avoids a tunnel, but your public URL and object access must let the destination fetch the media.

See [crier's tunnel guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/staging/tunnels.md) for command arguments, URL discovery and custom tunnels. **Check setup** tests the selected staging target and checks whether the tunnel executable is available.
