# Keyboard and mouse guide

[← Back to README](../README.md)

Uppercase letters mean Shift plus the letter. Key names come from MPV's input syntax; `KP0`–`KP9` are the numeric keypad. Most letter controls also have uppercase aliases, as recorded in `input.conf`.

## Playback and navigation

| Key | Action |
|---|---|
| Space | Toggle pause; at the end of a video, play it again |
| Left / Right | Seek −1 / +1 second (actual landing can depend on keyframes) |
| KP0–KP9 | Jump to 0%, 10%, … 90% |
| Alt+J | Open the console with a time-position command ready to edit |
| `>` | Next prefetched upload on the same YouTube channel; otherwise next playlist item |
| `<` | Previous playlist item |
| Alt+Right / Alt+Left | Next / previous frame |
| PgUp / PgDn | Chapter +1 / −1, respectively (custom order) |
| R | Cycle current-item looping → playlist looping → off |
| Alt+R | Toggle infinite looping of the current file |
| Alt+L | Cycle A → B → clear for A–B looping |
| Q | Quit |

To restart immediately, right-click the Tethys play button or enter `script-message replay` in the console. R changes looping instead.

## Speed, audio and subtitles

| Key | Action |
|---|---|
| W / S | Increase / decrease speed by 0.1× |
| F1 / F2 / F3 | Speed 2× / 1.5× / 1× |
| Up / Down, wheel up / down | Volume +5 / −5 |
| M | Mute |
| A | Cycle audio tracks |
| C | Toggle subtitle visibility |
| J | Cycle subtitle tracks |
| Z / X | Subtitle delay +0.1 / −0.1 seconds |
| Alt+Z / Alt+X | Subtitle delay −0.1 / +0.1 seconds |
| Alt+Shift+Z | Reset subtitle delay |
| Ctrl+Z / Ctrl+X | Audio delay −0.1 / +0.1 seconds |
| Ctrl+Shift+Z | Reset audio delay |
| Ctrl+Up / Right / Down / Left | Move volume OSD to top / right / bottom / left |

## Window, menus and tools

| Key / mouse | Action |
|---|---|
| F / Enter / keypad Enter | Toggle fullscreen |
| Esc | Leave fullscreen (or close an active menu) |
| Double left-click | Toggle fullscreen |
| Right-click | Play / pause; at the end of a video, play it again (over the Tethys play button: always replay from start) |
| P | Managed picture-in-picture |
| Alt+O | Toggle always-on-top |
| Alt+T | Toggle native window borders |
| Alt+S | PNG screenshot, stored under `portable_config/screenshots` |
| I | Statistics overlay |
| F5 | MPV version, output and decoder |
| F7 | Codec, size and audio information |
| F12 | Console |
| F6 / Alt+W | Video / audio menu: stream formats for URLs; resolution choice (original, 720p, 480p ...) and track choice for local files |
| Alt+E | RGX color enhancement; sharpening needs the separately supplied CAS shader |
| Alt+C | Cookie-source status |
| Ctrl+V | Open clipboard URL/path |
| Ctrl+D | Download current network URL with yt-dlp |
| Ctrl+H | Watch history grid |
| Ctrl+G | Current YouTube channel's uploads |

## Menu navigation

**Quality:** Up/Down or wheel, Enter/left-click to select, Esc/right-click to close.

**History/channel grid:** arrows or wheel, Enter/keypad Enter to play, PgUp/PgDn for pages, Home/End for first/last, Esc/Backspace to close. Delete removes a watch-history item; channel entries cannot be deleted here. Mouse selection is not implemented by the history grid.

Game Mode and SponsorBlock's upstream default keys are not enabled by this keymap. `no-input-default-bindings` disables weak script keys as well as MPV's default table. Add explicit `script-binding` mappings if you want those actions.
