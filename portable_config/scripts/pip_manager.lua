-- pip_manager.lua
-- Picture-in-Picture toggle (bound to p/P, and the Tethys PiP button).
-- Single owner of PiP; coordinates with window_state.lua through
-- user-data/pip_manager/active (read synchronously there) and window-state-*.
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
-- Bumped on every enter/exit. Every timer/observer captures it and bails if it
-- changed, so a quick p-p-p can never let an old step resize the window.
local generation = 0
local wait_observer
-- Everything PiP changes, captured before entering so exit puts it all back.
-- Without this, exit left autofit-larger/geometry at the old window size
-- (capping every later file) and always forced ontop off.
local pre = nil

-- What other scripts see. Kept separate from pip_active because some exits
-- must hide PiP from window_state a moment later than PiP really ends.
local function publish_flag(active)
    -- user-data is visible to other scripts immediately (unlike script-message races).
    mp.set_property_native("user-data/pip_manager/active", active and true or false)
    mp.commandv("script-message", "window-state-pip", active and "1" or "0")
end

local function set_pip_flag(active)
    pip_active = active
    publish_flag(active)
end

local timers = {}

local function cancel_pending()
    generation = generation + 1
    -- Kill outright; the generation check in after() is the backstop.
    for _, t in ipairs(timers) do t:kill() end
    timers = {}
    if wait_observer then
        mp.unobserve_property(wait_observer)
        wait_observer = nil
    end
end

local function after(delay, gen, fn)
    timers[#timers + 1] = mp.add_timeout(delay, function()
        if gen == generation then fn() end
    end)
end

local function capture_pre()
    local w = mp.get_property_number("osd-width")
    local h = mp.get_property_number("osd-height")
    local fs = mp.get_property_bool("fullscreen") == true
    local max = mp.get_property_bool("window-maximized") == true
    pre = {
        fullscreen    = fs,
        maximized     = max,
        ontop         = mp.get_property_bool("ontop") == true,
        autofit       = mp.get_property("autofit-larger") or "",
        geometry      = mp.get_property("geometry") or "",
    }
    -- osd size is only the user's window size when not fullscreen/maximized.
    -- Otherwise window_state.lua already holds the windowed size it saved
    -- before fs/maximize, which it re-applies on its own.
    if not fs and not max and w and h and w > 64 and h > 64 then
        pre.w, pre.h = math.floor(w + 0.5), math.floor(h + 0.5)
    end
end

local function apply_pip(gen)
    if gen ~= generation or not pip_active then return end
    if mp.get_property_bool("fullscreen") or mp.get_property_bool("window-maximized") then return end

    -- Lift size caps so the 33% geometry is not forced back up by autofit-larger.
    mp.set_property("autofit-larger", "100%x100%")
    mp.set_property("geometry", PIP_GEOMETRY)
    mp.set_property_bool("ontop", true)
    mp.osd_message("▣  PiP: On", 2)
end

local function enter_pip()
    cancel_pending()
    capture_pre()

    -- Snapshot the preferred size while the window is still a normal window.
    -- A forced snapshot in fullscreen/maximized would save the screen size.
    if not pre.fullscreen and not pre.maximized then
        mp.commandv("script-message", "window-state-snapshot")
    end

    -- Flag first: window_state ignores the fs/maximize changes below.
    set_pip_flag(true)
    local gen = generation

    if not pre.fullscreen and not pre.maximized then
        apply_pip(gen)
        return
    end

    -- Geometry is ignored while fullscreen/maximized: leave both, then apply
    -- once the window manager has actually finished the transition.
    wait_observer = function()
        if gen ~= generation then return end
        if mp.get_property_bool("fullscreen") or mp.get_property_bool("window-maximized") then return end
        if wait_observer then
            mp.unobserve_property(wait_observer)
            wait_observer = nil
        end
        after(0.1, gen, function() apply_pip(gen) end)
    end
    mp.set_property_bool("fullscreen", false)
    mp.set_property_bool("window-maximized", false)
    mp.observe_property("fullscreen", "bool", wait_observer)
    mp.observe_property("window-maximized", "bool", wait_observer)
end

-- Put back the option values PiP overwrote. Shared by normal exit and by
-- "user went fullscreen while in PiP".
local function restore_options(p)
    mp.set_property_bool("ontop", p.ontop)
    if p.autofit ~= "" then mp.set_property("autofit-larger", p.autofit) end
end

local function exit_pip()
    cancel_pending()
    local p = pre or { ontop = false, autofit = "", geometry = "" }
    pre = nil
    local gen = generation

    if p.fullscreen or p.maximized then
        -- Keep the flag on while switching back, so window_state does not
        -- snapshot the small PiP window as the size to restore later. Its
        -- saved windowed size is still the one from before PiP.
        -- pip_active goes false now so our own fullscreen observer ignores this.
        pip_active = false
        restore_options(p)
        if p.geometry ~= "" then mp.set_property("geometry", p.geometry) end
        if p.fullscreen then
            mp.set_property_bool("fullscreen", true)
        else
            mp.set_property_bool("window-maximized", true)
        end
        after(0.3, gen, function() publish_flag(false) end)
        mp.osd_message("▣  PiP: Off", 2)
        return
    end

    set_pip_flag(false)
    restore_options(p)

    -- Step 1: clear the edge-relative anchor left by PiP geometry.
    -- Without this, WxH alone keeps the window stuck in a corner (often bottom-left).
    mp.set_property("geometry", NORMAL_GEOMETRY)

    local w, h = p.w, p.h
    -- Step 2: after the WM settles, restore the previous pixel size (centered).
    after(0.08, gen, function()
        if w and h then
            local size = string.format("%dx%d", w, h)
            mp.set_property("autofit-larger", size)
            -- Size + center: clears any residual edge anchor.
            mp.set_property("geometry", size)
            after(0.05, gen, function()
                mp.set_property("geometry", NORMAL_GEOMETRY)
                -- Re-apply size once more so center + size stick.
                mp.set_property("geometry", size)
                -- Leave the options as they were before PiP so later files
                -- are sized by window_state's rules, not by this window.
                restore_options(p)
            end)
        else
            mp.set_property_number("window-scale", 1.0)
            mp.set_property("geometry", NORMAL_GEOMETRY)
            restore_options(p)
        end
    end)

    mp.osd_message("▣  PiP: Off", 2)
end

mp.register_script_message("pip-managed", function()
    if pip_active then
        exit_pip()
    else
        enter_pip()
    end
end)

-- Going fullscreen while in PiP ends PiP. Restore ontop/autofit now, but keep
-- the flag briefly: window_state reacts to the same fullscreen change on its
-- own thread and must still see PiP, or it saves the PiP window as the size
-- to return to after fullscreen.
mp.observe_property("fullscreen", "bool", function(_, is_fs)
    if is_fs and pip_active then
        cancel_pending()
        local gen = generation
        restore_options(pre or { ontop = false, autofit = "" })
        pre = nil
        pip_active = false
        after(0.3, gen, function() publish_flag(false) end)
        mp.msg.info("pip_manager: fullscreen triggered, PiP state cleared")
    end
end)
