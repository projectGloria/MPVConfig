-- seek_osd.lua
-- Displays a centered overlay showing the current playback position
-- whenever a seek is performed via LEFT / RIGHT arrow keys.
--
-- Triggered by input.conf:
--   RIGHT   no-osd seek  1 ; script-message show-seek-osd
--   LEFT    no-osd seek -1 ; script-message show-seek-osd
--
-- Placement: ~~/scripts/seek_osd.lua

local mp = require "mp"

-- Track OSC bottom margin dynamically
local margin_b = 0
mp.observe_property("user-data/osc/margins", "native", function(name, val)
    margin_b = (val and val.b) and val.b or 0
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- CENTERED OSD OVERLAY
-- ─────────────────────────────────────────────────────────────────────────────
local overlay       = mp.create_osd_overlay("ass-events")
overlay.res_x       = 1920
overlay.res_y       = 1080
overlay.z           = 150    -- above Lyra bg (100), below F6 menu (500) and Tethys (1000)
local overlay_timer = nil
local FONT          = "Montserrat ExtraBold"

local function show_center(line1, line2, duration)
    if overlay_timer then overlay_timer:kill(); overlay_timer = nil end
    overlay:remove()

    local ow, oh = mp.get_osd_size()
    overlay.res_x = (ow and ow > 0) and ow or 1920
    overlay.res_y = (oh and oh > 0) and oh or 1080

    -- 40px base spacing from bottom + dynamically adapt to UI height
    local bottom_spacing = 40
    local pos_x = math.floor(overlay.res_x / 2)
    local pos_y = math.floor(overlay.res_y - bottom_spacing - (margin_b * overlay.res_y))

    -- Scale fonts with window size (design base ~1280 wide).
    local scale = math.max(0.55, math.min(1.25, overlay.res_x / 1280))
    local fs1 = math.max(22, math.floor(48 * scale + 0.5))
    local fs2 = math.max(18, math.floor(40 * scale + 0.5))

    -- Dynamic \\an2 (Bottom-Center) alignment
    overlay.data = string.format(
        "{\\an2\\pos(%d,%d)\\fn%s\\fs%d\\bord2.5\\1c&HFFFFFF&\\3c&H000000&}%s"  ..
        "\\N{\\fn%s\\fs%d\\bord1.5\\1c&HBBBBBB&\\3c&H000000&}%s",
        pos_x, pos_y, FONT, fs1, line1, FONT, fs2, line2
    )
    overlay:update()
    overlay_timer = mp.add_timeout(duration, function()
        overlay:remove()
        overlay_timer = nil
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TIME FORMATTER-- ─────────────────────────────────────────────────────────────────────────────
-- TIME FORMATTER  →  "1:23:45"  or  "23:45"
-- ─────────────────────────────────────────────────────────────────────────────
local function fmt_time(secs)
    secs = math.floor(secs or 0)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%d:%02d", m, s)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HANDLER — called by input.conf after every seek
-- ─────────────────────────────────────────────────────────────────────────────
mp.register_script_message("show-seek-osd", function()
    local pos  = mp.get_property_number("time-pos") or 0
    local pct  = mp.get_property_number("percent-pos") or 0
    local dur  = mp.get_property_number("duration") or 0

    local line1 = fmt_time(pos)
    local line2

    if dur > 0 then
        line2 = string.format("%.0f%%   of   %s", pct, fmt_time(dur))
    else
        line2 = string.format("%.0f%%", pct)
    end

    show_center(line1, line2, 1.5)
end)