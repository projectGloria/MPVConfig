-- dwm_styling.lua
-- Removes the default Windows 11 DWM 1-pixel gray/white outline border around
-- rounded windows, preserving clean borderless 5px rounded corners.
-- Placement: ~~/scripts/dwm_styling.lua

local mp = require "mp"

local function suppress_border(wid)
    if not wid or wid == 0 then return end
    local ok, ffi = pcall(require, "ffi")
    if not ok or not ffi then return end

    pcall(function()
        ffi.cdef[[
            typedef void* HWND;
            typedef unsigned long DWORD;
            typedef long HRESULT;
            HRESULT DwmSetWindowAttribute(HWND hwnd, DWORD dwAttribute, const void* pvAttribute, DWORD cbAttribute);
        ]]
        local dwmapi = ffi.load("dwmapi")
        local hwnd = ffi.cast("HWND", wid)
        -- DWMWA_BORDER_COLOR = 34, DWMWA_COLOR_NONE = 0xFFFFFFFE (suppresses the outline border)
        local color = ffi.new("DWORD[1]", 0xFFFFFFFE)
        dwmapi.DwmSetWindowAttribute(hwnd, 34, color, 4)
    end)
end

local function reapply()
    local wid = mp.get_property_number("window-id")
    if wid and wid ~= 0 then
        suppress_border(wid)
    end
end

-- Apply on window initialization
mp.observe_property("window-id", "number", function(_, wid)
    if wid and wid ~= 0 then
        suppress_border(wid)
    end
end)

-- Re-apply when exiting fullscreen / maximize back to windowed mode
mp.observe_property("fullscreen", "bool", function(_, is_fs)
    if not is_fs then
        mp.add_timeout(0.1, reapply)
    end
end)

mp.observe_property("window-maximized", "bool", function(_, max)
    if not max then
        mp.add_timeout(0.1, reapply)
    end
end)
