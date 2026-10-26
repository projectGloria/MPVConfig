-- Save user choices, never transient pause state or file-specific track numbers.
local mp = require "mp"
local utils = require "mp.utils"
local path = mp.command_native({"expand-path", "~~/playback-preferences.json"})
local saved = {}
local file = io.open(path, "r")
if file then
    saved = utils.parse_json(file:read("*a")) or {}
    file:close()
end
if type(saved) ~= "table" then saved = {} end
local properties = {
    ["sub-visibility"] = "boolean", volume = "number",
    mute = "boolean", speed = "number", ["sub-scale"] = "number",
}
for name, kind in pairs(properties) do
    if type(saved[name]) == kind then
        mp.set_property_native(name, saved[name])
    end
end

local function save()
    local f, err = io.open(path, "w")
    if not f then mp.msg.warn("Cannot save playback preferences: " .. tostring(err)); return end
    f:write(utils.format_json(saved))
    f:close()
end
local timer
local function changed()
    if timer then timer:kill() end
    timer = mp.add_timeout(0.4, save)
end
for name, kind in pairs(properties) do
    mp.observe_property(name, "native", function(_, value)
        if type(value) == kind and saved[name] ~= value then
            saved[name] = value
            changed()
        end
    end)
end

local loaded = false
mp.register_event("start-file", function() loaded = false end)
mp.register_event("end-file", function() loaded = false end)
mp.add_hook("on_preloaded", 50, function()
    if saved.subtitles_disabled then mp.set_property("sid", "no") end
end)
mp.register_event("file-loaded", function() loaded = true end)
mp.observe_property("sid", "native", function(_, value)
    if not loaded or value == nil then return end
    local has_subtitles = false
    for _, track in ipairs(mp.get_property_native("track-list", {})) do
        if track.type == "sub" then has_subtitles = true end
    end
    if not has_subtitles then return end
    local disabled = value == "no" or value == false
    if saved.subtitles_disabled ~= disabled then
        saved.subtitles_disabled = disabled
        changed()
    end
end)
mp.register_script_message("replay", function()
    if not mp.get_property("path") then return end
    mp.commandv("seek", 0, "absolute+exact")
    mp.set_property_bool("pause", false)
end)
mp.register_event("shutdown", save)
