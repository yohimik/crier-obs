# Develop the script

The source is under `plugin/src/crier_obs`. External effects go through injected ports. Modules return tables; runtime functions return `nil, {kind, message, hint}` for failure. OBS replaces global `error` with a logging hook, so runtime control flow must not call it. `assert` remains for invariants.

Use LuaJIT 2.1, busted 2.3, LuaCov 0.17, luacheck 1.2, shellcheck and actionlint. LuaRocks dependencies must be visible to LuaJIT. On the development Mac:

```sh
export PATH="$HOME/.luarocks/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"
eval "$(luarocks --lua-version=5.1 --lua-dir=/opt/homebrew/opt/luajit path)"
dispat run lint --since all
dispat run shellcheck --since all
dispat run actionlint --since all
dispat run registry --since all
dispat run tests --since all
dispat run bundle-check --since all
```

Tests disable JIT before coverage begins. Coverage counts untested runtime files as misses, enforces 95% overall and 90% per module, and requires 100% for the pure modules named in the gate. Windows uses plain steps rather than dispat; it is informational until two verified green runs. The native POSIX suite runs on macOS and Linux. Fake Win32 tests validate Windows API construction; a Windows runner is needed for the real API behavior. Manual real-OBS verification on Windows and Linux is still required before claiming those environments were checked interactively.

The OBS stub tracks references, properties, callback identities, timer catch-up and event delivery. The bundle smoke loads the delivered script with OBS's nonthrowing `error` behavior, builds every registry property, drives a stream lifecycle and verifies native spawning where available. Process tests stress GC between pointer construction and native calls. Any Lua string or cdata put into an ffi array or struct must remain anchored until the call returns.

`plugin/crier.version` pins both the generated registry and installer. `tools/gen_registry.lua <crier-repo> [init.json]` reads reference tables from that exact git tag. `tools/registry_gate.sh` cross-checks the official pinned binary's full JSON sample and compares the generated output. The weekly sync workflow updates the pin and opens a tested pull request; it does not merge it. Crier's own [development guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/development.md) covers upstream changes.

`tools/bundle.lua` wraps modules in `package.preload`, embeds the HTML template, and requires the entry point. `DISPAT_NEW_VERSION=1.1.0-rc.0 sh plugin/tools/build.sh` stamps and verifies a release candidate locally without publishing. Only CI invokes releases. Use conventional scoped commits such as `fix(crier-obs): scrub a failed response`. The first feature commit uses `feat(crier-obs)%rc:`. The changelog's `authors.placement: both` includes commit authors and co-author trailers; use the actual author identity supplied by the coding harness.

One 500 ms heartbeat pumps processes and the scheduler. There is no `script_tick`. Keep UI updates and timer work nonblocking. OBS's Lua scripting API has no Qt bindings, so a Qt dock UI cannot be built here. A linked dispat control repository for crier and crier-obs is a separate future task.
