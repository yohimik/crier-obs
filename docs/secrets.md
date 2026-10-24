# Save credentials

Password fields are write-only. Paste a token and press **Save credentials** under the field. The script clears the OBS value at once, stores the token through the backend, reads it back, and shows `stored ✓` only when those bytes match. A failed save shows `not stored: <reason>` and keeps the typed value in memory, so the next **Save credentials** retries it. Press **Refresh results** after the operation finishes.

OBS's autosave moves a typed value into that memory and clears the field. It never stores a credential. A value typed without pressing **Save credentials** is dropped when the script unloads, with the warning `Credentials typed but not saved`. Unticking a destination keeps its credentials. **Forget credentials** deletes that field's value from every store. **Forget all credentials in this credential set**, in **Advanced**, deletes every value in the named set.

| OS | Store |
| --- | --- |
| macOS | the login Keychain, through `/usr/bin/security` with the value on a pipe; items use the service `crier-obs` |
| Windows | DPAPI blobs for the current user, under `secrets` in the state folder |
| Linux | Secret Service through `secret-tool`, with the attribute `service crier-obs`; or a private encrypted file |

At load on Linux, the script stores, reads back and deletes a random test value in Secret Service. If that fails, it logs `Secret Service unavailable; credentials use the encrypted file store`, and the **Credential store** row reads `Encrypted credential file (Secret Service unavailable)`. The file store uses ChaCha20-Poly1305 with a random nonce per record, a key file with mode 0600 and records in a 0700 `secrets` folder. Its protection depends on your OS account and filesystem access.

An index, `secrets/index.json`, records the store each value was saved in. If that store later becomes unavailable, the **Credential status** row reads `stored in keyring (keyring unavailable: <store>)`, naming the store, or that store's own reason, such as `Credential store is locked; unlock it and try again`. The script never moves a value into another store on its own, and never starts crier with an empty token in its place. Unlock your keychain or restore Secret Service and retry.

## Accounts

Accounts are named `<credential set>/<crier key>`, such as `default/publish.telegram.token`. Collections that select the same **Credential set** share accounts.

Credentials reach crier only through its environment, under crier's own names, such as `CRIER_PUBLISH_TELEGRAM_TOKEN`; see [crier's secrets](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md#secrets). A post gets only the keys its ticked platforms need, plus `stage.s3.access-key` and `stage.s3.secret-key` when `stage.mode` is `s3`, or when a base file decides `stage.mode` because you have not set it. Version checks and the installer get none. Inherited `CRIER_*` variables are removed before the post's own values are added.

## What stays in memory

The status rows ask whether a value exists. They never keep it. On Linux, `secret-tool` has no presence query, so a status check reads the value and drops it.

Only a live session keeps values: the credentials resolved when the stream starts, and those any post resolves during the stream. The quit post uses them, so it never waits for a keyring during shutdown. They are dropped when the end post starts, when a stream ends without one, and when the script unloads. Saving or forgetting a credential drops that value.

Lua strings cannot be reliably zeroed. Every log line, status row and saved run output is scrubbed of the values the script has seen, in their raw, URL-encoded and JSON-escaped spellings. A forgotten value stays on that list until the script unloads.
