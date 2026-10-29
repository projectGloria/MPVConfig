# Third-party notices

This repository collects independent configuration files, custom scripts and modified upstream scripts. It is not an official MPV, Tethys, yt-dlp or SponsorBlock release. Do not interpret a project's name here as an endorsement.

No repository-wide license is assigned to material of unspecified ownership. Existing license headers remain in the source. The texts in `licenses/` were retrieved from upstream on 26 October 2026; `licenses/sources.json` records URLs and hashes. They document upstream licensing and do not prove the exact upstream revision of every locally modified file.

| Component | Local location / use | Upstream and license notes |
|---|---|---|
| MPV autoload | `portable_config/scripts/autoload.lua` | Derived from [MPV's autoload script](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autoload.lua). MPV's GPL/LGPL texts and Copyright inventory are included; component-specific terms must be retained. |
| Tethys OSC | `portable_config/scripts/osc_tethys.lua` | Customized [Zren/mpv-osc-tethys](https://github.com/Zren/mpv-osc-tethys). Its upstream root does not expose a standalone LICENSE file in the inspected listing. The overall licensing of the combined script must not be assumed to be MIT. |
| MPV OSC foundations | Incorporated in Tethys | See [MPV](https://github.com/mpv-player/mpv), preserved references in the script and the included Copyright/license texts. |
| thumbfast | `portable_config/scripts/thumbfast.lua` (unmodified) | [po5/thumbfast](https://github.com/po5/thumbfast), MPL-2.0 license text included as `thumbfast-LICENSE.txt`. Supplies Tethys seekbar thumbnails on demand. Retrieved 29 October 2026; replaces the previously embedded (and disabled) TheAMM/mpv_thumbnail_script client and its SHA-1 module, which were removed from Tethys. |
| Bomi/morden icon/UI work | Referenced by Tethys upstream and source | Tethys identifies bomi icons; the local script also links to [maoiscat/mpv-osc-morden](https://github.com/maoiscat/mpv-osc-morden). Preserve these references; full provenance of the composite needs clarification. |
| Quality menu | `portable_config/scripts/quality-menu.lua` | Modified [christoph-heinrich/mpv-quality-menu](https://github.com/christoph-heinrich/mpv-quality-menu), local header version 4.2.1 (2025-06-29). Upstream GPL-2.0 license text included. Its README credits reload.lua, mpv-playlistmanager and ytdl_hook.lua. |
| SponsorBlock integration | `extras/sponsorblock` | [po5/mpv_sponsorblock](https://github.com/po5/mpv_sponsorblock), GPL-3.0 license text included. Uses the [SponsorBlock](https://github.com/ajayyy/SponsorBlock) API. Inactive in the default package. |

The existing local changes to Tethys include UI sizing/control integrations, replay/loop controls, a thumbfast-based seekbar thumbnail client and a PiP button that forwards to `pip_manager.lua`. The quality menu has curated-format handling, custom presentation and local setting actions. See source comments for individual modifications. Their exact pre-packaging revision/author history was not available.

Packaging-specific changes are recorded in [SHARING_NOTES.md](SHARING_NOTES.md). A fresh license grant for custom material would need to come from its owner; this package does not overwrite third-party terms with a blanket license.

## External tools and fonts — not bundled

[MPV](https://mpv.io/), [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org/), [Deno](https://deno.com/), [Python](https://www.python.org/) and [Montserrat](https://fonts.google.com/specimen/Montserrat) are downloaded/installed separately and retain their own terms.

`docs/assets/banner.svg` is an original illustrative asset created for this package. It is not a playback screenshot or an official project logo.
