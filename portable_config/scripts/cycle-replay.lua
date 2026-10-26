-- cycle-replay.lua
-- Cycles: Current video (1) → Directory/Playlist (all) → Off
-- Icons follow the exact same structure as play_pause_indicator.lua

local mp = require "mp"

local overlay = mp.create_osd_overlay("ass-events")
overlay.res_x = 1920
overlay.res_y = 1080
overlay.z = 2000

local timer = nil

-- Same convention as play/pause:
--   {\p1}m 0 0   m 100 100   <filled path>{\p0}

-- Current item: single circular arrow (refresh style)
local icon_current = "{\\p1}m 0 0   m 100 100   " ..
    -- outer ring arc + arrow head (filled)
    "m 50 12 " ..
    "b 29 12 12 29 12 50 " ..
    "b 12 71 29 88 50 88 " ..
    "b 66 88 80 79 86 65 " ..
    "l 76 61 " ..
    "b 72 70 62 76 50 76 " ..
    "b 36 76 24 64 24 50 " ..
    "b 24 36 36 24 50 24 " ..
    "b 60 24 68 29 73 37 " ..
    "l 60 37 " ..
    "l 60 52 " ..
    "l 88 52 " ..
    "l 88 24 " ..
    "l 76 24 " ..
    "b 69 16 60 12 50 12 " ..
    "{\\p0}"

-- Directory / all: circular arrow + three list bars (matches your screenshot)
local icon_playlist = "{\\p1}m 0 0   m 100 100   " ..
    -- circular arrow (slightly left)
    "m 38 12 " ..
    "b 20 12 6 26 6 44 " ..
    "b 6 62 20 76 38 76 " ..
    "b 52 76 63 68 68 56 " ..
    "l 59 53 " ..
    "b 56 60 48 65 38 65 " ..
    "b 27 65 18 56 18 44 " ..
    "b 18 32 27 23 38 23 " ..
    "b 46 23 52 27 56 33 " ..
    "l 46 33 " ..
    "l 46 46 " ..
    "l 70 46 " ..
    "l 70 22 " ..
    "l 60 22 " ..
    "b 54 16 46 12 38 12 " ..
    -- three horizontal bars (right side)
    "m 78 30   l 96 30   l 96 37   l 78 37   l 78 30 " ..
    "m 78 46   l 96 46   l 96 53   l 78 53   l 78 46 " ..
    "m 78 62   l 96 62   l 96 69   l 78 69   l 78 62 " ..
    "{\\p0}"

-- Off: ring + slash
local icon_off = "{\\p1}m 0 0   m 100 100   " ..
    -- outer circle
    "m 50 12 " ..
    "b 29 12 12 29 12 50 " ..
    "b 12 71 29 88 50 88 " ..
    "b 71 88 88 71 88 50 " ..
    "b 88 29 71 12 50 12 " ..
    -- inner hole
    "m 50 24 " ..
    "b 64 24 76 36 76 50 " ..
    "b 76 64 64 76 50 76 " ..
    "b 36 76 24 64 24 50 " ..
    "b 24 36 36 24 50 24 " ..
    -- slash
    "m 30 28   l 72 70   l 66 76   l 24 34   l 30 28 " ..
    "{\\p0}"

local function show_indicator(icon)
    if timer then timer:kill() end

    local start_time = mp.get_time()
    local duration = 0.6

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

        overlay.data = string.format(
            "{\\an5\\pos(960,540)\\fscx%d\\fscy%d\\alpha&H%02X&}%s",
            scale, scale, alpha, icon
        )
        overlay:update()
    end)
end

local function cycle_replay()
    local loop_file     = mp.get_property("loop-file")
    local loop_playlist = mp.get_property("loop-playlist")

    if loop_file == "inf" then
        -- 1 → all
        mp.set_property("loop-file", "no")
        mp.set_property("loop-playlist", "inf")
        show_indicator(icon_playlist)
    elseif loop_playlist == "inf" then
        -- all → off
        mp.set_property("loop-playlist", "no")
        show_indicator(icon_off)
    else
        -- off → 1
        mp.set_property("loop-file", "inf")
        show_indicator(icon_current)
    end
end

mp.add_key_binding(nil, "cycle-replay", cycle_replay)
