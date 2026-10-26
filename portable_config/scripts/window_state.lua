-- window_state.lua
-- Single authority for window size, position, fullscreen, maximize, ontop, border.
--
-- Fixes:
--   1. Leaving fullscreen often left an almost-fullscreen window.
--   2. User choices (size, position, FS, ontop, border) were not remembered.
--   3. Multi-monitor: window stayed on a disconnected display.
--   4. Competing geometry setters (old window_lock, pip_manager, conf autofit).
--
-- Placement: ~~/scripts/window_state.lua
-- State file: ~~/window-state.json
-- Options:   ~~/script-opts/window_state.conf

local mp    = require "mp"
local utils = require "mp.utils"
local opt   = require "mp.options"

local o = {
    -- Preferred windowed size when no saved state exists (percentage of screen).
    default_autofit = "70%x70%",
    -- Center on first open if no saved geometry.
    default_geometry = "50%:50%",
    -- How long to wait after leave-fullscreen before restoring geometry (seconds).
    fs_settle = 0.12,
    -- Poll interval for display-change detection (seconds). 0 = disable poll.
    display_poll = 2.0,
    -- Max concurrent size-lock applies after file load.
    lock_delay = 0.18,
    -- Persist ontop / border across sessions.
    persist_ontop = true,
    persist_border = true,
}
opt.read_options(o, "window_state")

local state_path = mp.command_native({"expand-path", "~~/window-state.json"})
local saved = {}
local applying = false
local pip_active = false          -- true while PiP owns geometry
local pre_fs = nil                -- snapshot taken just before entering fullscreen
local locked_w, locked_h          -- preferred pixel size for new files
local last_display_count = nil
local generation = 0

local function is_pip()
    if pip_active then return true end
    -- user-data is set synchronously by pip_manager (avoids script-message races).
    local v = mp.get_property_native("user-data/pip_manager/active")
    return v == true or v == "true" or v == "yes" or v == 1
end

------------------------------------------------------------------------
-- Persistence
------------------------------------------------------------------------
local function load_state()
    local f = io.open(state_path, "r")
    if not f then return end
    local ok, data = pcall(utils.parse_json, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
        saved = data
    end
end

local function save_state()
    local f, err = io.open(state_path, "w")
    if not f then
        mp.msg.warn("window_state: cannot write " .. tostring(err))
        return
    end
    f:write(utils.format_json(saved))
    f:close()
end

local save_timer = nil
local function schedule_save()
    if save_timer then save_timer:kill() end
    save_timer = mp.add_timeout(0.35, save_state)
end

load_state()

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function get_osd_wh()
    local w = mp.get_property_number("osd-width")
    local h = mp.get_property_number("osd-height")
    if w and h and w > 64 and h > 64 then
        return math.floor(w + 0.5), math.floor(h + 0.5)
    end
    return nil, nil
end

local function current_geometry_string()
    -- Prefer explicit pixel geometry when we have size; fall back to property.
    local w, h = get_osd_wh()
    local geo = mp.get_property("geometry") or ""
    if w and h then
        -- Try to keep x/y from current geometry if present.
        local x, y = geo:match("([%+%-]%d+)([%+%-]%d+)$")
        if x and y then
            return string.format("%dx%d%s%s", w, h, x, y)
        end
        -- Percentage form or empty → store size only; position restored by VO.
        return string.format("%dx%d", w, h)
    end
    return geo ~= "" and geo or nil
end

local function snapshot_windowed(force)
    if not force then
        if mp.get_property_bool("fullscreen") then return end
        if mp.get_property_bool("window-maximized") then return end
        if is_pip() then return end
    end
    local w, h = get_osd_wh()
    if w and h then
        locked_w, locked_h = w, h
        saved.w = w
        saved.h = h
        saved.geometry = current_geometry_string()
        saved.window_scale = mp.get_property_number("window-scale")
        schedule_save()
    end
end

local function apply_geometry(geo, also_autofit)
    if not geo or geo == "" then return end
    applying = true
    generation = generation + 1
    local gen = generation
    mp.set_property("geometry", geo)
    if also_autofit and locked_w and locked_h then
        mp.set_property("autofit-larger", string.format("%dx%d", locked_w, locked_h))
    end
    mp.add_timeout(o.lock_delay, function()
        if gen == generation then
            applying = false
        end
    end)
end

local function restore_windowed_geometry()
    if is_pip() then return end
    local geo = (pre_fs and pre_fs.geometry) or saved.geometry
    if not geo or geo == "" then
        if locked_w and locked_h then
            geo = string.format("%dx%d", locked_w, locked_h)
        else
            geo = o.default_geometry
        end
    end
    -- Clear maximized first so geometry can take effect.
    if mp.get_property_bool("window-maximized") then
        mp.set_property_bool("window-maximized", false)
    end
    apply_geometry(geo, true)
    pre_fs = nil
end

------------------------------------------------------------------------
-- Apply saved preferences on startup
------------------------------------------------------------------------
local function apply_startup()
    if saved.w and saved.h and saved.w > 64 and saved.h > 64 then
        locked_w, locked_h = saved.w, saved.h
        mp.set_property("autofit-larger", string.format("%dx%d", locked_w, locked_h))
    else
        mp.set_property("autofit-larger", o.default_autofit)
    end

    if saved.geometry and saved.geometry ~= "" then
        mp.set_property("geometry", saved.geometry)
    else
        mp.set_property("geometry", o.default_geometry)
    end

    if o.persist_ontop and type(saved.ontop) == "boolean" then
        mp.set_property_bool("ontop", saved.ontop)
    end
    if o.persist_border and type(saved.border) == "boolean" then
        mp.set_property_bool("border", saved.border)
    end

    -- Never start in fullscreen from saved state (user must choose).
    -- Maximized is also not restored automatically to avoid multi-monitor traps.
end

apply_startup()

------------------------------------------------------------------------
-- Fullscreen transitions
------------------------------------------------------------------------
mp.observe_property("fullscreen", "bool", function(_, is_fs)
    if applying then return end
    if is_fs then
        -- Entering fullscreen: remember current windowed geometry.
        if not is_pip() then
            local w, h = get_osd_wh()
            pre_fs = {
                geometry = current_geometry_string(),
                w = w, h = h,
                window_scale = mp.get_property_number("window-scale"),
            }
            if w and h then
                locked_w, locked_h = w, h
                saved.w, saved.h = w, h
                saved.geometry = pre_fs.geometry
                schedule_save()
            end
        end
    else
        -- Leaving fullscreen: restore previous windowed size/position.
        -- Small delay lets the window manager finish the FS exit.
        local gen = generation
        mp.add_timeout(o.fs_settle, function()
            if gen ~= generation then return end
            if mp.get_property_bool("fullscreen") then return end
            if is_pip() then return end
            restore_windowed_geometry()
        end)
    end
end)

------------------------------------------------------------------------
-- User resize / maximize
------------------------------------------------------------------------
mp.observe_property("osd-dimensions", "native", function(_, dim)
    if applying or not dim or is_pip() then return end
    if mp.get_property_bool("fullscreen") then return end
    local w, h = dim.w, dim.h
    if not w or not h or w <= 64 or h <= 64 then return end
    -- Adopt user-driven size changes.
    if not locked_w or math.abs(w - locked_w) > 2 or math.abs(h - locked_h) > 2 then
        locked_w = math.floor(w + 0.5)
        locked_h = math.floor(h + 0.5)
        saved.w, saved.h = locked_w, locked_h
        if not mp.get_property_bool("window-maximized") then
            saved.geometry = current_geometry_string()
        end
        schedule_save()
    end
end)

mp.observe_property("window-maximized", "bool", function(_, max)
    if applying or is_pip() then return end
    if max then
        -- Remember size before maximize so we can restore later.
        snapshot_windowed()
    else
        -- Leaving maximize: re-apply locked size if we have one.
        if locked_w and locked_h and not mp.get_property_bool("fullscreen") then
            mp.add_timeout(0.08, function()
                if not mp.get_property_bool("window-maximized")
                   and not mp.get_property_bool("fullscreen")
                   and not is_pip() then
                    apply_geometry(string.format("%dx%d", locked_w, locked_h), true)
                end
            end)
        end
    end
end)

mp.observe_property("ontop", "bool", function(_, v)
    if type(v) == "boolean" and o.persist_ontop then
        saved.ontop = v
        schedule_save()
    end
end)

mp.observe_property("border", "bool", function(_, v)
    if type(v) == "boolean" and o.persist_border then
        saved.border = v
        schedule_save()
    end
end)

------------------------------------------------------------------------
-- Keep preferred size when opening a new file (old window_lock behaviour)
------------------------------------------------------------------------
mp.add_hook("on_load", 1, function()
    if is_pip() or mp.get_property_bool("fullscreen") then return end
    if locked_w and locked_h then
        apply_geometry(string.format("%dx%d", locked_w, locked_h), true)
    end
end)

mp.register_event("file-loaded", function()
    if is_pip() or mp.get_property_bool("fullscreen") then return end
    mp.add_timeout(0.05, function()
        if locked_w and locked_h and not applying and not is_pip() then
            apply_geometry(string.format("%dx%d", locked_w, locked_h), true)
        end
    end)
    -- Capture size after first settle if we still have none.
    mp.add_timeout(0.25, function()
        if not locked_w and not is_pip() then
            snapshot_windowed()
        end
    end)
end)

------------------------------------------------------------------------
-- Multi-monitor recovery
-- When a display disappears, move the window onto a still-connected one.
------------------------------------------------------------------------
local function display_count()
    local names = mp.get_property_native("display-names")
    if type(names) == "table" then return #names end
    -- Fallback: some builds expose current-window-display only.
    local cur = mp.get_property("current-window-display")
    return cur and 1 or 0
end

local function relocate_to_primary()
    if mp.get_property_bool("fullscreen") then
        -- Exit FS first so we can move, then re-enter if desired.
        -- Safer to just force a centered windowed geometry on primary.
        mp.set_property_bool("fullscreen", false)
    end
    applying = true
    -- Center on whatever is now primary / available.
    mp.set_property("geometry", o.default_geometry)
    if locked_w and locked_h then
        mp.set_property("autofit-larger", string.format("%dx%d", locked_w, locked_h))
        -- Also set explicit size so VO does not expand to full screen.
        mp.add_timeout(0.1, function()
            mp.set_property("geometry", string.format("%dx%d", locked_w, locked_h))
            applying = false
            saved.geometry = string.format("%dx%d", locked_w, locked_h)
            schedule_save()
            mp.osd_message("Window moved to available display", 2)
        end)
    else
        applying = false
        mp.osd_message("Window moved to available display", 2)
    end
end

local function check_displays()
    local n = display_count()
    if last_display_count == nil then
        last_display_count = n
        return
    end
    if n < last_display_count and n >= 1 then
        -- A monitor disappeared.
        mp.msg.info(string.format("window_state: display count %d → %d, relocating", last_display_count, n))
        relocate_to_primary()
    end
    last_display_count = n
end

if o.display_poll and o.display_poll > 0 then
    mp.add_periodic_timer(o.display_poll, check_displays)
end

-- Also react immediately when mpv reports display-names change.
mp.observe_property("display-names", "native", function()
    check_displays()
end)

------------------------------------------------------------------------
-- Coordination with pip_manager
------------------------------------------------------------------------
mp.register_script_message("window-state-pip", function(active)
    local was = pip_active
    pip_active = (active == "1" or active == "true" or active == true)
    if was and not pip_active then
        -- Leaving PiP: adopt the size pip_manager just restored (after a beat).
        mp.add_timeout(0.25, function()
            snapshot_windowed(true)
        end)
    end
end)

-- Public helper: pip_manager calls this right before enter / right after exit.
mp.register_script_message("window-state-snapshot", function()
    snapshot_windowed(true)
end)

mp.register_event("shutdown", function()
    if not mp.get_property_bool("fullscreen") and not is_pip() then
        snapshot_windowed()
    end
    save_state()
end)

mp.msg.info("window_state: loaded (geometry persistence + multi-monitor recovery)")
