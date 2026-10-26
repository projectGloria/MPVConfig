-- pip_manager.lua
-- Picture-in-Picture toggle (bound to p/P). Coordinates with window_state.lua.
--
-- Placement: ~~/scripts/pip_manager.lua
-- Options:   ~~/script-opts/pip_manager.conf

local mp  = require "mp"
local opt = require "mp.options"

local o = {
    -- Must use +-X+-Y form so mpv treats offsets as from the right/bottom edges.
    -- "33%-10-10" is ambiguous and often lands bottom-left on Windows.
    pip_geometry    = "33%+-10+-10",
    normal_geometry = "50%:50%",
}
opt.read_options(o, "pip_manager")

local PIP_GEOMETRY    = o.pip_geometry
local NORMAL_GEOMETRY = o.normal_geometry

local pip_active = false
local entry_timer, entry_observer
local entry_generation = 0
local pre_pip = nil  -- { w, h }

local function set_pip_flag(active)
    pip_active = active
    -- user-data is visible to other scripts immediately (unlike script-message races).
    mp.set_property_native("user-data/pip_manager/active", active and true or false)
    mp.commandv("script-message", "window-state-pip", active and "1" or "0")
end

local function cancel_entry()
    entry_generation = entry_generation + 1
    if entry_timer then entry_timer:kill(); entry_timer = nil end
    if entry_observer then
        mp.unobserve_property(entry_observer)
        entry_observer = nil
    end
end

local function capture_pre_pip()
    local w = mp.get_property_number("osd-width")
    local h = mp.get_property_number("osd-height")
    if w and h and w > 64 and h > 64 then
        pre_pip = { w = math.floor(w + 0.5), h = math.floor(h + 0.5) }
    else
        pre_pip = nil
    end
end

local function do_pip_enter()
    if not pip_active then return end
    if mp.get_property_bool("fullscreen") then return end

    -- Lift size caps so the 33% geometry is not forced back up by autofit-larger.
    mp.set_property("autofit-larger", "100%x100%")
    mp.set_property("geometry", PIP_GEOMETRY)
    mp.set_property_bool("ontop", true)
    mp.osd_message("▣  PiP: On", 2)
end

local function enter_pip()
    cancel_entry()

    if not mp.get_property_bool("fullscreen") then
        capture_pre_pip()
    end
    -- Snapshot preferred size while still large (forced snapshot).
    mp.commandv("script-message", "window-state-snapshot")

    set_pip_flag(true)
    local generation = entry_generation

    if mp.get_property_bool("fullscreen") then
        mp.set_property_bool("fullscreen", false)
        entry_observer = function(_, is_fs)
            if generation ~= entry_generation then return end
            if is_fs == false then
                if entry_observer then
                    mp.unobserve_property(entry_observer)
                    entry_observer = nil
                end
                entry_timer = mp.add_timeout(0.1, function()
                    if generation ~= entry_generation then return end
                    entry_timer = nil
                    if not pre_pip then capture_pre_pip() end
                    do_pip_enter()
                end)
            end
        end
        mp.observe_property("fullscreen", "bool", entry_observer)
    else
        do_pip_enter()
    end
end

local function exit_pip()
    cancel_entry()
    set_pip_flag(false)
    mp.set_property_bool("ontop", false)

    local w = pre_pip and pre_pip.w
    local h = pre_pip and pre_pip.h

    -- Step 1: clear the edge-relative anchor left by PiP geometry.
    -- Without this, WxH alone keeps the window stuck in a corner (often bottom-left).
    mp.set_property("geometry", NORMAL_GEOMETRY)

    -- Step 2: after the WM settles, restore the previous pixel size (centered).
    mp.add_timeout(0.08, function()
        if pip_active then return end
        if w and h and w > 64 and h > 64 then
            mp.set_property("autofit-larger", string.format("%dx%d", w, h))
            -- Size + center: clears any residual edge anchor.
            mp.set_property("geometry", string.format("%dx%d", w, h))
            mp.add_timeout(0.05, function()
                if not pip_active then
                    mp.set_property("geometry", NORMAL_GEOMETRY)
                    -- Re-apply size once more so center + size stick.
                    mp.set_property("autofit-larger", string.format("%dx%d", w, h))
                    mp.set_property("geometry", string.format("%dx%d", w, h))
                end
            end)
        else
            mp.set_property_number("window-scale", 1.0)
            mp.set_property("geometry", NORMAL_GEOMETRY)
        end
        mp.commandv("script-message", "window-state-snapshot")
    end)

    pre_pip = nil
    mp.osd_message("▣  PiP: Off", 2)
end

mp.register_script_message("pip-managed", function()
    if pip_active then
        exit_pip()
    else
        enter_pip()
    end
end)

mp.observe_property("fullscreen", "bool", function(_, is_fs)
    if is_fs and pip_active then
        cancel_entry()
        mp.set_property_bool("ontop", false)
        set_pip_flag(false)
        pre_pip = nil
        mp.msg.info("pip_manager: fullscreen triggered, PiP state cleared")
    end
end)
