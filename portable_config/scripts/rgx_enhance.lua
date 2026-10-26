-- rgx_enhance.lua
-- Toggles "RGX Enhance" mode — Opera GX-style video enhancement via mpv's
-- native GPU post-processing pipeline (no external filters, hwdec-safe).
--
-- What it does:
--   Sharpness  +18  →  Edges crisper, fine detail recovered
--   Saturation +15  →  Colours more vivid
--   Contrast    +6  →  Mild lift — punches up perceived depth
--   Gamma       −4  →  Slight negative gamma pulls out shadow detail
--
-- Toggle key: Alt+e  (set in input.conf)
-- Persists across files in the same session; resets on mpv restart.

local mp = require "mp"

-- ─────────────────────────────────────────────────────────────────────────────
-- CENTERED OSD OVERLAY
-- ─────────────────────────────────────────────────────────────────────────────
local overlay       = mp.create_osd_overlay("ass-events")
overlay.res_x       = 1920
overlay.res_y       = 1080
local overlay_timer = nil
local FONT          = "Montserrat ExtraBold"

local function show_center(line1, line2, duration)
    if overlay_timer then overlay_timer:kill(); overlay_timer = nil end
    overlay:remove()

    local body
    if line2 then
        body = string.format(
            "{\\an5\\pos(960,540)\\fn%s\\fs48\\bord2.5\\1c&HFFFFFF&\\3c&H000000&}%s"  ..
            "\\N{\\fn%s\\fs40\\bord1.5\\1c&HBBBBBB&\\3c&H000000&}%s",
            FONT, line1, FONT, line2
        )
    else
        body = string.format(
            "{\\an5\\pos(960,540)\\fn%s\\fs48\\bord2.5\\1c&HFFFFFF&\\3c&H000000&}%s",
            FONT, line1
        )
    end

    overlay.data = body
    overlay:update()
    overlay_timer = mp.add_timeout(duration, function()
        overlay:remove()
        overlay_timer = nil
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ENHANCEMENT PROFILE
-- ─────────────────────────────────────────────────────────────────────────────
local PROFILE = {
    saturation =  15,
    contrast   =   6,
    gamma      =  -4,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- STATE
-- ─────────────────────────────────────────────────────────────────────────────
local enhanced = false
local baseline = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- APPLY / RESTORE
-- ─────────────────────────────────────────────────────────────────────────────
local props = { "saturation", "contrast", "gamma" }

-- portable_config/shaders/CAS.glsl is not shipped with this repo. Appending a missing
-- shader makes gpu-next log an error on every load, so only touch the list if it exists.
local CAS_PATH = "~~/shaders/CAS.glsl"
local function cas_available()
    local info = require("mp.utils").file_info(mp.command_native({"expand-path", CAS_PATH}))
    return info ~= nil and info.is_file
end

local function apply_enhance()
    for _, prop in ipairs(props) do
        baseline[prop] = mp.get_property_number(prop) or 0
    end
    for prop, value in pairs(PROFILE) do
        mp.set_property_number(prop, value)
    end
    if cas_available() then
        mp.commandv("change-list", "glsl-shaders", "append", CAS_PATH)
    end
    enhanced = true
    show_center(
        cas_available() and "RGX Enhance (AMD CAS)  —  ON" or "RGX Enhance  —  ON",
        string.format("%s  ·  Sat +%d  ·  Con +%d",
            cas_available() and "AMD CAS Shader Active" or "CAS.glsl missing: colour only",
            PROFILE.saturation, PROFILE.contrast),
        3
    )
end

local function restore_baseline()
    for _, prop in ipairs(props) do
        mp.set_property_number(prop, baseline[prop] or 0)
    end
    mp.commandv("change-list", "glsl-shaders", "remove", CAS_PATH)
    enhanced = false
    show_center("RGX Enhance  —  OFF", "Baseline restored", 2)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PUBLIC TOGGLE
-- ─────────────────────────────────────────────────────────────────────────────
local function toggle_enhance()
    if not enhanced then apply_enhance() else restore_baseline() end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HOOKS
-- ─────────────────────────────────────────────────────────────────────────────
mp.register_script_message("rgx-toggle", toggle_enhance)

-- Re-apply when a new file loads mid-session (mode persists across files)
mp.register_event("file-loaded", function()
    if enhanced then
        for prop, value in pairs(PROFILE) do
            mp.set_property_number(prop, value)
        end
        mp.commandv("change-list", "glsl-shaders", "remove", CAS_PATH)
        if cas_available() then
            mp.commandv("change-list", "glsl-shaders", "append", CAS_PATH)
        end
    end
end)
