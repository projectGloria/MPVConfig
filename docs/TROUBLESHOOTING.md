# Troubleshooting

[← Back to README](../README.md)

## MPV opens without this interface

Check that `portable_config` is directly beside the **mpv.exe you actually launched**, not inside another nested extraction folder. Confirm `portable_config/scripts/osc_tethys.lua` exists. Close/reopen the player. Another running installation may receive your file through the shared single-instance pipe; see [multiple installs](CUSTOMIZATION.md#runtime-state-and-multiple-installs).

## A YouTube video will not load

1. Confirm `portable_config/yt-dlp.exe` exists and update it with `-U`.
2. Check Deno is installed and available on PATH, then restart MPV.
3. Leave browser cookies disabled for an ordinary public video. Enable them deliberately only when authentication is necessary.
4. Press F12 for errors. A site can change independently of this configuration; compare with a direct yt-dlp command.

The separate channel/history/download helpers do not inherit every playback extraction option. A working video with a failing channel grid can therefore be a helper-options issue. See [yt-dlp's support documentation](https://github.com/yt-dlp/yt-dlp#readme).

## No thumbnails

Run `ffmpeg -version` in a new terminal. FFmpeg needs to be on PATH; putting it only inside `portable_config` does not necessarily make it discoverable by these scripts. A short local clip may not have a frame at the history generator's fixed ten-second timestamp. Small history cards currently omit bitmaps rather than resize them. Channel thumbnails can require reopening the page after generation completes.

Seekbar hover thumbnails are intentionally disabled, and their worker is not included. History thumbnails and loading covers are separate features.

## Opening a video takes too long

Keep `enabled=no` in `script-opts/loading_preview.conf`. Its optional ffmpeg job currently delays media loading. The history/channel features also prefetch background data, even when their menus stay closed. Missing/stalled network dependencies can make those features sluggish. SponsorBlock is optional and inactive by default because its retry bug can repeatedly contact the API.

## PiP size, position or always-on-top behaves strangely

There are known geometry, maximize and temporary-state issues. Press P to leave PiP, then F to change fullscreen state deliberately. To reset persisted preferences, close MPV and rename `portable_config/window-state.json`; the next launch uses defaults. Avoid combining this setup with another window/PiP manager.

## Colors look unusual

Toggle Alt+E off. RGX applies saturation, contrast and gamma changes; no CAS sharpening shader is bundled. HDR output also depends on Windows HDR settings and your actual display; this preset is not a display-calibration profile.

## A font looks different

Install Montserrat ExtraBold or select your preferred installed font. Some overlays hard-code their font, so changing only mpv.conf is not enough. See [Fonts and subtitles](CUSTOMIZATION.md#fonts-and-subtitles).

## A preference keeps coming back

Runtime preferences override some startup settings. Close MPV and rename the appropriate local state file to reset it:

| File | Reset |
|---|---|
| `playback-preferences.json` | Volume, mute, speed and subtitle preferences |
| `window-state.json` | Saved size, ontop and border preferences |
| `volume-osd-position.txt` | Volume overlay placement |
| `mpv-history.txt` | Watch history |

Keep backups if you want to restore them later. Do not upload these files to an issue.

## Reporting a problem

Include the MPV version (F5 or `mpv.com --version`), Windows version, GPU, local-versus-streaming context, and the smallest steps that reproduce it. State whether cookies, SponsorBlock or loading covers were enabled.

For a **local** test file, launch from the installed player directory with:

```powershell
.\mpv.com --log-file=mpv-debug.log 'C:\path\to\sample.mp4'
```

Read/scrub logs before sharing: they can contain personal file paths, private URLs, titles and extraction data. Never include cookie files or browser databases.
