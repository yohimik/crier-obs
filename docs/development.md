# Develop the script

The source is under `plugin/src/crier_obs`. External effects go through injected ports. Modules return tables; runtime functions return `nil, {kind, message, hint}` for failure. OBS replaces the global `error` with a logging hook, so runtime control flow must not call it. `assert` remains for invariants.

One 500 ms heartbeat pumps processes and the scheduler. There is no `script_tick`. Keep UI updates and timer work nonblocking. OBS's Lua scripting API has no Qt bindings, so a Qt dock cannot be built here.

## Tools

Use LuaJIT 2.1, busted 2.3.0, LuaCov 0.17.0, luacheck 1.2.0, StyLua 2.6.0 (`brew install stylua`), shellcheck, actionlint and dispat 1.10.0. The LuaRocks packages must be visible to LuaJIT. On the development Mac, from the repository root:

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

## The gates

Each gate is a script in `dispat.yaml`, run from `plugin/`. The `tools/*.sh` gates change into `plugin/` themselves, so `sh plugin/tools/test.sh` works from anywhere.

| Gate | Runs |
| --- | --- |
| `lint` | `tools/lint.sh`: `luacheck src tools spec`, `stylua --check src spec tools` with `plugin/stylua.toml`, then fails if runtime code calls the global `error`, `os.execute` or `io.popen`; `plugin/.styluaignore` leaves the generated registry alone |
| `shellcheck` | `shellcheck` over `tools/*.sh` and the shell fakes in `spec/fakes` |
| `actionlint` | `actionlint` over `.github/workflows/*.yml` |
| `registry` | `tools/registry_gate.sh`: regenerates the registry from the pinned crier and fails on any difference |
| `tests` | `tools/test.sh`: every spec, then `tools/coverage_gate.lua` |
| `bundle-check` | `tools/bundle_check.sh`: builds the bundle, smokes it, and runs the end-to-end specs against it |

**Formatting.** StyLua formats `src`, `spec` and `tools/*.lua` with tabs and 120 columns. The generated `src/crier_obs/registry/*.lua` files are excluded, so the registry gate compares the generator's own output byte for byte. CI installs StyLua with Homebrew on macOS and with `tools/install_stylua.sh` on Linux, which downloads the pinned 2.6.0 release and checks its SHA-256 digest.

**Tests.** `spec/helper.lua` disables JIT before LuaCov starts. It loads every `crier_obs` chunk in an environment whose `error` and `print` behave like OBS's hooks. The coverage gate counts untested source files as misses. It requires 95% overall, 90% per module, and 100% for the pure modules it names. The OBS stub in `spec/stub` tracks references, properties, callback identities, timer catch-up and event delivery. Process specs stress the garbage collector between building a pointer and the native call. Any Lua string or cdata put into an ffi array or struct must stay anchored until the call returns. Specs tagged `posix` need a POSIX host.

**Registry.** `tools/registry_gate.sh` clones crier at the pinned tag into `.cache/v<pin>/source`. It downloads that release's `crier-<os>-<arch>` binary and checks it against the SHA-256 digest GitHub publishes. Then it writes the binary's `crier init --full --format json` output and regenerates `src/crier_obs/registry/*.lua` with it. Any difference from the committed files fails. It needs macOS or Linux. Set `GITHUB_TOKEN` to avoid the anonymous API limit.

**Bundle check.** `tools/bundle_check.sh` bundles `dist/crier-obs.lua` as version `0.0.0-ci` and compiles it with `luajit -bl`. It fails unless the bundle holds exactly the modules under `src/crier_obs`. The bundle embeds `templates/live.html` as the default card. `src/` runs use the copy in `src/crier_obs/templates.lua`, and `spec/unit/templates_spec.lua` fails when the two differ by a byte. Then it runs two checks on the bundle:

- `tools/smoke.lua` loads the bundle alone. Only the OBS stub comes from the checkout, and a module the bundle lacks fails the smoke rather than loading from `src/`. It runs the script with OBS's nonthrowing `error`, builds every registry property, and posts a start and an end through the fake crier with native spawning. Then it checks the generated configuration, the data document, the captions, the released references and timers, and that no error was logged. It finds the stub and the fake crier from its own path, so `luajit plugin/tools/smoke.lua plugin/dist/crier-obs.lua` works from the repository root as well as from `plugin/`.
- `spec/e2e` runs again with `CRIER_OBS_E2E_BUNDLE=dist/crier-obs.lua`, so the lifecycle specs exercise the delivered chunk instead of `src/`.

## CI

`tests.yml` runs on every push to `main`, on pull requests, when `release.yml` calls it, and on a manual dispatch. Ubuntu and macOS install the tools, set up dispat 1.10.0 and run all six gates with `dispat run <gate> --since all`. They upload `luacov.report.out`.

The Windows job does not use dispat; it runs plain steps. It sets up MSVC, LuaJIT 2.1 and LuaRocks, and builds the Go fake `spec/fakes/crier_win/crier.exe`. If busted 2.3.0 and LuaCov 0.17.0 install, it runs every spec with `--exclude-tags=posix`, then bundles and smokes against the Go fake. If they do not install, it runs the bundle and the smoke alone. Windows never runs lint, shellcheck, actionlint, the registry gate, the coverage gate or the bundle's end-to-end specs. The job is `continue-on-error` until two verified green runs. The fake Win32 layer in `spec/fakes/win32.lua` checks Windows API construction on every host; this job is where the real API runs.

Manual real-OBS verification on Windows and Linux is still required before saying those environments were checked interactively.

## Following crier

`plugin/crier.version` pins the generated registry, the installer and every crier link in these docs. To regenerate by hand, from `plugin/`:

```sh
luajit tools/gen_registry.lua <crier-checkout> [init.json]
```

It reads `crier.version` and the reference tables under `docs/configuration` at that tag through `git -C <crier-checkout>`, so the checkout must have the tag. It writes `src/crier_obs/registry/*.lua` relative to the working directory. With the second argument, it also checks every key's kind and default against the binary's `crier init --full --format json` output. `tools/registry_gate.sh` supplies that file.

The **crier registry sync** workflow (`crier-sync.yml`) runs weekly and on demand. `tools/crier_sync.sh` reads crier's latest stable release and stops when it is not newer than the pin, or when a pull request for it is already open. Otherwise it:

1. creates the branch `crier-sync/v<version>` and bumps `plugin/crier.version`,
2. regenerates the registry from a clone at the new tag, then runs `tools/update_pin.lua`, which moves the crier links and `crier v<version>` references in `README.md` and `docs`, and `CRIER_VERSION` in `version.lua`,
3. runs the registry, lint, tests and bundle-check gates in the job,
4. commits `feat(crier-obs): follow crier v<version>`, pushes the branch and opens a pull request,
5. runs `gh workflow run tests.yml` on that branch.

A pull request opened with `GITHUB_TOKEN` starts no workflow of its own, which is why the job runs the gates itself and then dispatches `tests.yml`; its checks report on the branch's head commit. Opening the pull request needs the repository setting "Allow GitHub Actions to create and approve pull requests". Nothing merges automatically. Crier's own [development guide](https://github.com/yohimik/crier/blob/v1.1.1/docs/operations/development.md) covers upstream changes.

## Building and committing

`tools/bundle.lua` wraps every module in `package.preload`, embeds the HTML template and requires the entry point. `DISPAT_NEW_VERSION=1.1.0-rc.0 sh plugin/tools/build.sh` stamps and verifies a release candidate locally without publishing it. Only CI publishes releases; see [releases](release.md).

Commits are conventional and scoped, such as `fix(crier-obs): scrub a failed response`. `dispat diagnostics --config dispat.yaml '<message>'` checks a message before you commit. The changelog's `authors.placement: both` lists commit authors and co-author trailers; use the author identity the coding harness supplies.
