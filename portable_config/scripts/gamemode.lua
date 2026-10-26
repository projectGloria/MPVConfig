local mp = require "mp"
local is_gamemode = false
local section_name = "gamemode_lock"
local script_name = mp.get_script_name()

local function toggle_gamemode()
    is_gamemode = not is_gamemode
    if is_gamemode then
        mp.osd_message("Game Mode: ON (Bindings Locked)", 2)
        mp.commandv("enable-section", section_name, "allow-hide-cursor+allow-vo-dragging+exclusive")
    else
        mp.osd_message("Game Mode: OFF", 2)
        mp.commandv("disable-section", section_name)
    end
end

mp.add_key_binding("alt+g", "toggle-gamemode", toggle_gamemode)

local binding_path = script_name .. "/toggle-gamemode"
local contents = string.format(
    "alt+g script-binding %s\nalt+G script-binding %s",
    binding_path, binding_path
)

mp.commandv("define-section", section_name, contents, "force")
