# Optional SponsorBlock integration

[← Back to the main README](../../README.md)

This extra uses [po5/mpv_sponsorblock](https://github.com/po5/mpv_sponsorblock) to fetch segment boundaries, add chapters and skip selected categories on YouTube. It requires Python 3 on PATH. See the included GPL-3.0 license and third-party notices.

**It is not enabled by default.** The included implementation has an unbounded API retry bug and can apply an old video's results to a new file. Prefer fixing those issues before enabling it; this source is retained to preserve the original setup's optional integration.

## Install explicitly

Close MPV, then copy:

1. `scripts/sponsorblock.lua` into the installed `portable_config/scripts/`.
2. The whole `scripts/sponsorblock_shared/` folder into that same scripts directory.
3. `script-opts/sponsorblock.conf` into the installed `portable_config/script-opts/`.

Do not copy only the Lua file; it depends on the Python helper. Keep `main.lua` with the helper folder.

The provided options fetch sponsor, intro, outro, interaction, self-promotion and filler categories, skipping the configured subset. They also enable skip reporting; auto-upvoting is disabled. Change `report_views=no` if you do not want skip reports. A local `sponsorblock.txt` identity may be created at runtime and must not be uploaded.

Upstream manual keys are disabled by this preset's `no-input-default-bindings`. If you want manual segment/vote controls, explicitly map named bindings in input.conf after reviewing their behavior. No submissions or votes are performed by installation itself.

To disable again, close MPV and move the integration's Lua/helper files outside the active scripts directory. Keep any local identity/private state out of this repository.
