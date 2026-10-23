# Add a custom destination

Select **Custom platforms**, then add names to the editable list. Names use lower-case letters, digits and dashes. A name cannot be one of the fourteen built-in destinations. Select a name in **Custom platform to configure** to edit its settings, and tick it in **Post to**.

Each name expands the 15 [custom platform settings](https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/publish/custom.md): enabled, command, ping command, caption, kinds, format, needs URL, timeout, overlays, dimensions, fit, background, attachment limit and environment entries. Enter environment entries as `VAR=value`; those become the custom command's environment map.

The publish command receives the artifact through [crier's custom command contract](https://github.com/yohimik/crier/blob/v1.1.1/docs/publishing/custom.md). Use a ping command that checks account access without publishing. Choose kinds that describe what the command actually accepts, especially before enabling replay posts.

Removing a name removes its destination from future model snapshots. Queued jobs keep their original snapshot. A renamed destination is a new configuration namespace; copy the settings you want to retain.
