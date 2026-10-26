-- speed_indicator.lua
-- Centered animated speed indicator (same style as play/pause)
-- Placement: ~~/scripts/speed_indicator.lua

local mp = require "mp"

local overlay = mp.create_osd_overlay("ass-events")
overlay.res_x = 1920
overlay.res_y = 1080
overlay.z = 2000

local timer = nil
local first = true
local last_speed = 1.0

-- Same path convention as play/pause: {\p1}m 0 0   m 100 100   ...{\p0}

-- Faster: double triangle pointing right
local icon_faster = "{\\p1}m 0 0   m 100 100   " ..
    "m 8 20   l 42 50   l 8 80   l 8 20   " ..
    "m 48 20   l 82 50   l 48 80   l 48 20   " ..
    "{\\p0}"

-- Slower: double triangle pointing left
local icon_slower = "{\\p1}m 0 0   m 100 100   " ..
    "m 92 20   l 58 50   l 92 80   l 92 20   " ..
    "m 52 20   l 18 50   l 52 80   l 52 20   " ..
    "{\\p0}"

-- Normal 1x: single play triangle
local icon_normal = "{\\p1}m 0 0   m 100 100   " ..
    "m 28 18   l 82 50   l 28 82   l 28 18   " ..
    "{\\p0}"

local function format_speed(speed)
    local s = string.format("%.1f", speed)
    if s:sub(-2) == ".0" then
        s = s:sub(1, -3)
    end
    return s .. "x"
end

local function show_indicator(speed)
    if timer then timer:kill() end

    local start_time = mp.get_time()
    local duration = 0.6
    local label = format_speed(speed)

    local icon
    if math.abs(speed - 1.0) < 0.05 then
        icon = icon_normal
    elseif speed > last_speed then
        icon = icon_faster
    elseif speed < last_speed then
        icon = icon_slower
    else
        icon = speed >= 1.0 and icon_faster or icon_slower
    end
    last_speed = speed

    timer = mp.add_periodic_timer(0.033, function()
        local now = mp.get_time()
        local progress = (now - start_time) / duration

        if progress >= 1 then
            overlay.data = ""
            overlay:update()
            timer:kill()
            timer = nil
            return
        end

        local alpha = math.floor(progress * progress * 255)
        local scale = 100 + math.floor(progress * 40)

        -- Keep icon + text tightly grouped around center
        -- Icon centered slightly left, text immediately to its right
        local icon_x = 930
        local text_x = 990
        local fs = math.floor(56 * scale / 100)

        overlay.data = string.format(
            "{\\an5\\pos(%d,540)\\fscx%d\\fscy%d\\alpha&H%02X&\\1c&HFFFFFF&}%s\n" ..
            "{\\an4\\pos(%d,540)\\fs%d\\b1\\alpha&H%02X&\\1c&HFFFFFF&\\bord3\\3c&H000000&}%s",
            icon_x, scale, scale, alpha, icon,
            text_x, fs, alpha, label
        )
        overlay:update()
    end)
end

mp.observe_property("speed", "number", function(_, speed)
    if first then
        first = false
        last_speed = speed or 1.0
        return
    end
    if type(speed) ~= "number" then return end
    show_indicator(speed)
end)
