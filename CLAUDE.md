# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A source-only, shareable MPV configuration for Windows 11 (D3D11, LuaJIT/FFI builds). `portable_config/` is copied next to `mpv.exe`; MPV auto-loads it. No binaries, runtime state, history, or cookies belong in the repo — `.gitignore` enforces this, so never commit generated files (`*.exe`, `watch_history/`, `playback-preferences.json`, `window-state.json`, `cookies*`, `sponsorblock.*`, etc.).

## Tests

There is no build. Tests are Lua scripts run inside MPV itself, from the **repo root** (paths are relative to `working-directory`), with `mpv.com` on PATH:

```powershell
mpv.com --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tests/regressions.lua
mpv.com --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tests/syntax.lua
mpv.com --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tests/download_paths.lua
```

Exit code is 0 on pass, 1 on failure (scripts call `quit` with the result).

- `syntax.lua` — `loadfile`s every `.lua` under `portable_config/scripts`, `portable_config/script-modules`, and `extras/sponsorblock/scripts` without executing them.
- `regressions.lua` — a `fixture(name)` harness that replaces `mp`, `mp.utils`, `mp.options`, and `io` via `package.loaded`, then `dofile`s a script. The fixture state `s` records `jobs` (async subprocesses), `commands`, `timers`, `events`, `messages`, `observers`, and a fake `files` table. Drive scripts with `s:event('file-loaded')`, `s:fire(delay)` (fires pending timers registered with that exact delay), `s.messages['name']()`, and by invoking `s.jobs[i].cb(...)` manually. To test a single scenario, there is no filter — temporarily trim `run()`, or add a new block following the existing pattern. Any new `mp` API a script uses must be added to the mock or the fixture crashes.
- `download_paths.lua` — loads `ytdlp_download.lua` with `setfenv` to fake `os.getenv`.

Tests never touch the network, real files, or cookies; keep it that way.

## Architecture

Scripts in `portable_config/scripts/` are independent MPV Lua scripts that coordinate through three channels rather than direct calls:

1. **`script-message`** — e.g. `osc_tethys.lua` registers `osc-idlescreen`, `osc-visibility`, `toggle-pip`; `playback_preferences.lua` owns `replay`; `window_state.lua` owns `window-state-pip`/`window-state-snapshot` (sent by `pip_manager.lua`); `input.conf` triggers many of these (`clipboard-paste`, `yt-channel-next`, `show-seek-osd`, …). Grep for the message name across `scripts/` and `input.conf` before renaming.
2. **`user-data/*` properties** — shared state readable synchronously (preferred over messages where ordering races matter, see `pip_manager.lua`): `user-data/osc/margins` (Tethys → history_menu, quality-menu layout), `user-data/osc/visibility`, `user-data/osc/idlescreen`, `user-data/pip_manager/active` (Tethys PiP button icon reads it).
3. **Shared yt-dlp metadata** — `script-modules/ytdl_metadata.lua` reads MPV's own `user-data/mpv/ytdl/json-subprocess-result` and returns it only if its `webpage_url`/`original_url` matches the current URL (by YouTube video ID). `history_menu`, `loading_preview`, `youtube-channel-next` use it to avoid spawning extra `yt-dlp` processes; `cookies_auto` observes the same property. Modules are loaded with `dofile(mp.command_native({"expand-path", "~~/script-modules/..."}))`, not `require`.

Other cross-cutting facts:
- `mpv.conf` sets `no-input-default-bindings` and `osc=no`: **every key must be bound in `input.conf`**, and `osc_tethys.lua` (≈5.7k lines, heavily customized upstream) replaces the built-in OSC.
- `single_instance.lua`'s `pipe_path` must match `input-ipc-server` in `mpv.conf` (`\\.\pipe\mpv-pipe`); changing one without the other breaks forwarding.
- Per-script options live in `script-opts/<script-name>.conf` and are read via `mp.options.read_options`.
- A recurring correctness pattern in tests: async callbacks/timers must not affect a file that has since changed (stale-callback guards on `start-file`). Preserve these when editing.
- `quality-menu.lua` serves two menus from one `text_menu_open`: streaming formats (has an extra "Auto" row) and local-file resolutions (`is_local=true`, no Auto row). Local choices add a labelled `@qmres` video filter: `d3d11vpp=scale=` when `hwdec-current` is `d3d11va` (software `scale` cannot read zero-copy D3D11 frames and the graph fails), plain `scale` otherwise. It is removed on `start-file` (vf is global) and rebuilt when `hwdec-current` changes.
- PiP has one owner, `pip_manager.lua`: it snapshots ontop/autofit-larger/geometry/fullscreen/maximized before entering and restores them on exit. Tethys's `toggle-pip` message and PiP button only forward `pip-managed` to it. When exiting into fullscreen/maximized it keeps `user-data/pip_manager/active` set ~0.3 s longer so `window_state.lua` (separate thread) does not snapshot the PiP window as the preferred size.
- Seekbar thumbnails: `thumbfast.lua` (unmodified upstream, MPL-2.0) is the backend. Tethys listens for `thumbfast-info` and sends `script-message-to thumbfast thumb <t> <x> <y>` / `clear` only when time or position changes. Don't re-embed a thumbnailer in Tethys.
- The Tethys `btn_quality` element renders the live resolution from `video-out-params` (post-filter, so local downscales show) (long/short edge thresholds), not a static icon.
- `extras/sponsorblock/` is deliberately outside the auto-loaded `scripts/` because of known bugs; it is opt-in only.

## Third-party code

`osc_tethys.lua`, `quality-menu.lua`, and `autoload.lua` are locally modified upstream scripts (licenses in `licenses/`, provenance in `THIRD_PARTY_NOTICES.md`). Don't replace them with upstream copies, and keep their license headers. No repo-wide license exists — don't add one.

`docs/KNOWN_ISSUES.md` lists unfixed bugs (e.g. window/PiP geometry, non-atomic state writes, SponsorBlock retries). Check it before "discovering" a bug, and update it when fixing one.
