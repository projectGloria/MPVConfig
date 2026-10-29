# Customize the player

[← Back to README](../README.md)

Edit text files with a UTF-8 editor and restart MPV. In MPV paths, `~~/` means the active configuration directory (`portable_config` in this install).

## Where to edit

| File | Controls |
|---|---|
| `mpv.conf` | Rendering, cache budgets, subtitles, screenshots, stream selector and profiles |
| `input.conf` | Explicit keyboard/mouse controls |
| `script-opts/tethys.conf` | Tethys bar sizing, icons/buttons and skip amounts |
| `script-opts/quality-menu.conf` | Curated streaming formats and menu appearance |
| `script-opts/history_menu.conf` | History size, grid scale and thumbnail concurrency |
| `script-opts/window_state.conf` | First-run window defaults and transition timing |
| `script-opts/pip_manager.conf` | PiP size/position requests |
| `script-opts/ytdlp_download.conf` | Completed/partial download directories |
| `script-opts/cookies_auto.conf` | Optional browser cookie selection |
| `script-opts/loading_preview.conf` | Optional loading covers and deadline |

Tethys also reads MPV OSC options from `script-opts/osc.conf` if you create it. For example `showwindowed=yes`, `showfullscreen=yes` and `hidetimeout=2000` belong there, not in `tethys.conf`.

## Rendering profiles

The base configuration uses `gpu-next`, D3D11 and `d3d11va`, with audio-clock synchronization, spline36 upscaling and debanding. Its stream selector prefers up to 1080p AV1, then VP9, with audio fallbacks. Its final `/best` fallback means the resolution limit is not absolute.

- **Local HQ:** activates for non-network files and requests display-resample with oversample frame blending.
- **4K:** activates at source width ≥3840 and reduces scaling/interpolation/debanding work. It is a source-width heuristic, not automatic hardware benchmarking.
- **Fast:** manual profile for lighter rendering. In the console, use `apply-profile fast`; `apply-profile fast restore` restores its captured options. There is no Alt+P shortcut.

If a GPU/codec combination does not support the explicit hardware decoder, try `hwdec=auto-safe` or `hwdec=no` to diagnose. Alt+H toggles between this preset's D3D11VA and software modes. Measure before selecting a different graphics API.

For local files, F6 lists the original resolution plus every standard lower one (1080p, 720p, 480p ...). A lower choice downscales on the GPU with `d3d11vpp` (or the `scale` filter when decoding in software), so it reduces rendering load, not decoding load. The choice resets for each new file. The Tethys quality button shows the current output resolution (720p / 1080p / 2K / 4K) and opens the same menu.

## Fonts and subtitles

The preset requests `Montserrat ExtraBold` in mpv.conf and custom overlays. Install that font, or replace the name in `mpv.conf`, `script-opts/*.conf` and the small OSD Lua scripts. Changing only `osd-font` does not change every custom overlay.

`sub-auto=fuzzy` finds similarly named subtitles. Adjust `sub-font-size`, outline and colors in mpv.conf. Subtitle visibility and scale are saved at runtime. The saved preference can override your initial settings on the next launch; close MPV and rename `playback-preferences.json` if you want to reset it.

## Downloads

Default destination: your Windows user folder's `Downloads/mpv`. Partial files use `Downloads/mpv/_incomplete`.

To use another folder, edit `script-opts/ytdlp_download.conf`:

```ini
directory=E:/Videos/mpv
temp_directory=E:/Videos/mpv/_incomplete
```

The downloader deliberately reads your usual yt-dlp configuration, which may affect format, cookies and other behavior. The playback cookie helper does not automatically configure this separate download process. Only one download can be started at a time by this script. Download files are not part of the repository.

## Optional covers and cookies

**Loading cover:** change `enabled=no` to `enabled=yes` in `loading_preview.conf`. FFmpeg must be on PATH. Existing code blocks media opening while preparing a missing cover, so leave it off if startup speed matters. The old `seconds` option was unused and is omitted from the shared options file.

**Cookies:** public videos should first be tried anonymously. For a video requiring authentication, enable `cookies_auto.conf` and select a browser/profile you control. Leave `firefox_profile` empty for automatic selection. Cookie extraction can fail or become stale; the helper retries once without its injected cookies. Never commit browser databases, exported cookies or your private cookie configuration. Refer to [yt-dlp's cookie guidance](https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp).

**SponsorBlock:** instructions are in [the optional extra](../extras/sponsorblock/README.md). It is not active in the default shared preset.

## Script map

| Script | Role |
|---|---|
| `osc_tethys.lua` | Vendored/customized Tethys interface; includes an inactive thumbnailer client |
| `quality-menu.lua` | Vendored/customized streaming format menus and experimental local settings |
| `autoload.lua` | Folder playlist population |
| `clipboard.lua` | Manual clipboard load and supported timestamp seeking |
| `history_menu.lua` | Persistent history, thumbnails and channel grid |
| `youtube-channel-next.lua` | Same-channel next-upload navigation |
| `ytdlp_download.lua` | Separate yt-dlp downloads |
| `cookies_auto.lua` | Optional browser-cookie injection/fallback |
| `loading_preview.lua` | Optional loading covers |
| `window_state.lua` | Window dimensions/preferences and attempted display recovery |
| `pip_manager.lua` | PiP toggle and coordination |
| `single_instance.lua` | Windows named-pipe forwarding to an existing player |
| `dwm_styling.lua` | Windows DWM outline styling using FFI |
| `playback_preferences.lua` | Preference persistence and replay message |
| `cycle-replay.lua` | Current/playlist/off looping indicator |
| `rgx_enhance.lua` | Color enhancement, plus CAS if a shader is supplied |
| `play_pause_indicator.lua`, `speed_indicator.lua` | Brief animated feedback |
| `seek_osd.lua`, `volume_osd.lua` | Position/volume feedback |
| `gamemode.lua` | Optional input-lock mode; needs an explicit key binding |
| `script-modules/ytdl_metadata.lua` | Reuses extracted metadata when its URL matches |

To disable a script, move it **outside** the `scripts` directory. Do not merely append `.disabled`: MPV can still scan it and emit an unknown-script warning. Moving a script may leave bindings or other scripts expecting it, so disable the associated controls too.

## Runtime state and multiple installs

Caches, watch history, screenshot files, `playback-preferences.json`, `window-state.json` and volume-OSD placement are local state. They are intentionally excluded by .gitignore. Window persistence is mainly size/preferences; position, maximize and monitor handling are not fully reliable.

The default named pipe is `\\.\pipe\mpv-pipe`. Two separate installations using it can forward into each other. To isolate an install, change **both** `input-ipc-server` in mpv.conf and `pipe_path` in `script-opts/single_instance.conf` to the same unique pipe. Disabling only the server option does not disable the forwarding script.
