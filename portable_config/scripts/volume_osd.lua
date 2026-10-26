-- volume_osd.lua
-- Visual volume bar overlay with configurable placement.
--
-- Left Ctrl + Arrow keys move the bar:
--   Ctrl+Up    = top
--   Ctrl+Right = right
--   Ctrl+Down  = bottom
--   Ctrl+Left  = left
--
-- Horizontal bars render on top/bottom.
-- Vertical bars render on left/right.

local mp  = require "mp"
local opt = require "mp.options"

local FONT = "Montserrat ExtraBold"

local cfg = {
    position      = "bottom", -- top / right / bottom / left
    scale         = 1.20,     -- overall size multiplier
    bar_length    = 460,      -- long edge in OSD units
    bar_thickness = 16,       -- short edge in OSD units
    top_margin    = 42,
    side_margin   = 42,
    label_gap     = 12,
    label_size    = 23,
    duration      = 1.8,
    volume_max    = 150,
}
opt.read_options(cfg, "volume_osd")

local POS = { top = true, right = true, bottom = true, left = true }
local position = POS[cfg.position] and cfg.position or "bottom"

-- Persist last Ctrl+arrow position across sessions.
local pos_path = mp.command_native({"expand-path", "~~/volume-osd-position.txt"})
do
    local f = io.open(pos_path, "r")
    if f then
        local saved = (f:read("*l") or ""):match("^%s*(%a+)%s*$")
        f:close()
        if saved and POS[saved] then position = saved end
    end
end

local function save_position()
    local f = io.open(pos_path, "w")
    if f then
        f:write(position)
        f:close()
    end
end

local function osd_size()
    local w, h = mp.get_osd_size()
    if not w or not h or w <= 0 or h <= 0 then
        return 1920, 1080
    end
    return math.floor(w), math.floor(h)
end

local function s(v)
    return math.max(1, math.floor((tonumber(v) or 0) * cfg.scale + 0.5))
end

local VOL_MAX   = math.max(1, tonumber(cfg.volume_max) or 150)
local BAR_LEN   = s(cfg.bar_length)
local BAR_THICK = s(cfg.bar_thickness)
local TOP_M     = s(cfg.top_margin)
local SIDE_M    = s(cfg.side_margin)
local GAP       = s(cfg.label_gap)
local FS        = s(cfg.label_size)
local DURATION  = tonumber(cfg.duration) or 1.8
local UNITY_FRAC = math.min(1, 100 / VOL_MAX)

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 150
local timer = nil
local margin_b = 0

mp.observe_property("user-data/osc/margins", "native", function(_, val)
    margin_b = (val and val.b) and val.b or 0
end)

local function rect(x, y, w, h, color_hex, alpha_byte)
    return string.format(
        "{\\an7\\pos(%d,%d)\\1c%s\\1a&H%02X&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
        math.floor(x), math.floor(y), color_hex, alpha_byte,
        math.floor(w), math.floor(w), math.floor(h), math.floor(h)
    )
end

local function label(x, y, txt)
    return string.format(
        "{\\an5\\pos(%d,%d)\\fn%s\\fs%d\\bord1.5\\1c&HFFFFFF&\\3c&H000000&}%s",
        math.floor(x), math.floor(y), FONT, FS, txt
    )
end

local function fill_color(vol, muted)
    if muted then
        return "&H666666&"
    elseif vol > 100 then
        return "&H00AAFF&"
    else
        return "&H00FF88&"
    end
end

local function label_text(vol, muted)
    local pct = math.floor((vol or 0) + 0.5)
    if muted then
        return string.format("Muted   %d%%", pct)
    end
    return string.format("Volume   %d%%", pct)
end

local function build_horizontal(vol, muted, canvas_w, canvas_h, at_top)
    local cx = math.floor(canvas_w / 2)
    -- at_top previously only moved the LABEL, so Ctrl+Up left the bar sitting
    -- at the bottom with its caption underneath. The bar itself moves now.
    -- Only the bottom placement needs to clear the OSC control bar.
    local top_y
    if at_top then
        top_y = TOP_M
    else
        top_y = canvas_h - TOP_M - math.floor(margin_b * canvas_h) - BAR_THICK
    end
    local left_x = math.floor(cx - BAR_LEN / 2)

    local frac = math.min(math.max(vol / VOL_MAX, 0), 1)
    local fill_w = math.max(math.floor(BAR_LEN * frac + 0.5), 0)
    local mk_x = left_x + math.floor(BAR_LEN * UNITY_FRAC + 0.5)

    local parts = {}
    table.insert(parts, rect(left_x, top_y, BAR_LEN, BAR_THICK, "&H111111&", 0x60))
    if fill_w > 0 then
        table.insert(parts, rect(left_x, top_y, fill_w, BAR_THICK, fill_color(vol, muted), 0x00))
    end
    table.insert(parts, rect(mk_x, top_y - 3, 2, BAR_THICK + 6, "&H888888&", 0x30))

    local label_y
    if at_top then
        label_y = top_y + BAR_THICK + GAP + FS
    else
        label_y = top_y - GAP
    end
    table.insert(parts, label(cx, label_y, label_text(vol, muted)))
    return table.concat(parts, "\n")
end

local function build_vertical(vol, muted, canvas_w, canvas_h, side)
    local cy = math.floor(canvas_h / 2)
    local bar_h = BAR_LEN
    local bar_w = BAR_THICK
    local left_x = (side == "left") and SIDE_M or (canvas_w - SIDE_M - bar_w)
    local top_y = math.floor(cy - bar_h / 2)

    local frac = math.min(math.max(vol / VOL_MAX, 0), 1)
    local fill_h = math.max(math.floor(bar_h * frac + 0.5), 0)
    local fill_y = top_y + bar_h - fill_h
    local mk_y = top_y + math.floor(bar_h * (1 - UNITY_FRAC) + 0.5)

    local parts = {}
    table.insert(parts, rect(left_x, top_y, bar_w, bar_h, "&H111111&", 0x60))
    if fill_h > 0 then
        table.insert(parts, rect(left_x, fill_y, bar_w, fill_h, fill_color(vol, muted), 0x00))
    end
    table.insert(parts, rect(left_x - 3, mk_y, bar_w + 6, 2, "&H888888&", 0x30))

    local label_x = (side == "left") and (left_x + bar_w + GAP + 110) or (left_x - GAP - 110)
    table.insert(parts, label(label_x, cy, label_text(vol, muted)))
    return table.concat(parts, "\n")
end

local function build_osd(vol, muted)
    local canvas_w, canvas_h = osd_size()
    if position == "top" or position == "bottom" then
        return build_horizontal(vol, muted, canvas_w, canvas_h, position == "top")
    end
    return build_vertical(vol, muted, canvas_w, canvas_h, position)
end

local function show()
    if timer then
        timer:kill()
        timer = nil
    end
    overlay:remove()

    local vol = mp.get_property_number("volume") or 100
    local muted = mp.get_property_bool("mute") or false
    local osd_w, osd_h = osd_size()
    overlay.res_x = osd_w
    overlay.res_y = osd_h
    overlay.data = build_osd(vol, muted)
    overlay:update()

    timer = mp.add_timeout(DURATION, function()
        overlay:remove()
        timer = nil
    end)
end

local function set_position(pos)
    if POS[pos] then
        position = pos
        save_position()
    end
    show()
end

mp.register_script_message("show-volume-osd", show)
mp.register_script_message("set-volume-osd-position", set_position)
