# Set up your first post

Add `crier-obs.lua` through **Tools → Scripts → +**. The **Status** rows show crier's version, the credential backend, the last run and the logs folder. Use **Install crier** when it is missing, or **Update crier** when the discovered version is older than the pinned v1.1.1. An explicit path in **Advanced** takes precedence over automatic discovery.

In **Posting**, tick each destination. The choices apply to every trigger and explicitly disable every unticked destination, including destinations enabled in a base file. Enter a title, game and stream URL. Add optional `key=value` custom fields. Change the enabled triggers and their captions as needed.

Choose **Platforms** in **Section**, then choose a platform. Fill the settings described by **How to get these values**, which opens that platform's [crier guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/publishing/README.md). For every password field, paste the value and press **Save credentials**. Typing alone does not commit it. A stored status appears after the asynchronous operation finishes; press **Refresh results** or change the navigator to see it.

Press **Check setup**, then **Refresh results**. It checks the executable, credentials, platform access and relevant external tools. A dry run prepares the render without publishing. **Post now** publishes with the manual caption.

The default card is 1080 × 1080 PNG with hermetic fonts. Select **Render** or **Video** to change [rendering settings](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/render/README.md). **Staging** holds [public URL settings](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/stage/README.md). **Advanced** holds a base file, crier path, credential set, timeouts, retention and logging.

OBS settings belong to the scene collection. Credentials belong to the named credential set, `default` initially. Two collections that select the same set share the credentials. Choose a separate set for a different account.
