-- play_pause_indicator.lua
-- Centered animated play/pause indicators
-- Placement: ~~/scripts/play_pause_indicator.lua

local mp = require 'mp'

local overlay = mp.create_osd_overlay("ass-events")
overlay.res_x = 1920
overlay.res_y = 1080
overlay.z = 2000

local timer = nil

-- SVG-like paths for play/pause icons (scaled to ~100x100)
local icon_play = "{\\p1}m 0 0   m 100 100   m 84.6 40   b 94.5 46.8 94.5 49.8 84.6 56.6   b 51.1 79.8 21.3 100 14.6 100   b 8 100 8 90 8 48.3   b 8 10 8 0 14.6 0   b 21.3 0 51.1 16.8 84.6 40{\\p0}"
local icon_pause = "{\\p1}m 0 0   m 100 100   m 39.7 91.3   b 39.7 102.8 10.2 102.8 10.2 91.3   l 10.2 8.6   b 10.2 -2.8 39.7 -2.8 39.7 8.6   m 89.7 91.3   b 89.7 102.8 60.2 102.8 60.2 91.3   l 60.2 8.6   b 60.2 -2.8 89.7 -2.8 89.7 8.6{\\p0}"

local function show_indicator(icon)
    if timer then timer:kill() end
    
    local start_time = mp.get_time()
    local duration = 0.6
    
    -- 30 fps is visually indistinguishable from 60 fps for this fade; half the OSD redraws
    timer = mp.add_periodic_timer(0.033, function()
        local now = mp.get_time()
        local elapsed = now - start_time
        local progress = elapsed / duration
        
        if progress >= 1 then
            overlay.data = ""
            overlay:update()
            timer:kill()
            timer = nil
            return
        end
        
        -- Animation: Scale up slightly and fade out
        local alpha = math.floor(progress * progress * 255)
        local scale = 100 + math.floor(progress * 40)
        
        overlay.data = string.format("{\\an5\\pos(960,540)\\fscx%d\\fscy%d\\alpha&H%02X&}%s", 
                                     scale, scale, alpha, icon)
        overlay:update()
    end)
end

local first_check = true
mp.observe_property("pause", "bool", function(name, paused)
    if first_check then
        first_check = false
        return
    end
    if paused then
        show_indicator(icon_pause)
    else
        show_indicator(icon_play)
    end
end)
