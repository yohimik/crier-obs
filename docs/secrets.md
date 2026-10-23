# Save credentials

Password fields are write-only. Paste a token and press **Save credentials**. The script clears the OBS user value immediately, saves through the backend, reads it back, and shows stored only when those bytes match. A failed save keeps the pending value in memory so you can retry. Press **Refresh results** after the operation finishes.

OBS autosave moves a typed value to a pending Lua table and unsets the field. It never commits credentials. A value typed without pressing Save is discarded when the script unloads, with a warning. Unticking a destination keeps its credentials. **Forget credentials** deletes the selected value; **Forget all credentials in this credential set** clears the named set.

| OS | Store |
| --- | --- |
| macOS | Login Keychain, through `security` with pipe input and output |
| Windows | DPAPI protected blobs under the local state folder |
| Linux | Secret Service through `secret-tool`, or a private encrypted file fallback |

The Linux fallback uses ChaCha20-Poly1305 with a random nonce, a 0600 key and ciphertext records in a 0700 directory. Its protection depends on your OS account and filesystem access. An index records the backend for each account. If a backend later becomes unavailable, the script reports that condition rather than silently moving a stored credential into another backend. Unlock your keychain or restore Secret Service and retry.

Accounts are named `<credential set>/<crier key>`. Collections sharing the same set share accounts. Credentials reach [crier's environment layer](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md) only through the child environment. Probes and installers receive no crier credentials. Inherited `CRIER_*` variables are removed before explicit invocation values are added.

Resolved credentials stay in memory during a live session so the quit trigger can start without waiting for the keyring. The cache is dropped after the end job starts or the script unloads. Lua strings cannot be reliably zeroed. Every emitted status and log string is scrubbed by the secret values registered for that session.
