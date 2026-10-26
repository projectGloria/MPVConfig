-- single_instance.lua
-- Enforces a single instance of MPV on Windows using named-pipe IPC.
-- When a secondary instance is launched (e.g. double-clicking a video in Explorer),
-- it forwards the file to the active primary instance, brings it to front, and terminates immediately.
--
-- Placement: ~~/scripts/single_instance.lua
-- Options:   ~~/script-opts/single_instance.conf

local mp    = require "mp"
local utils = require "mp.utils"
local opt   = require "mp.options"

local o = {
    action     = "replace",      -- "replace" or "append-play" or "append"
    unminimize = true,
    pipe_path  = "\\\\.\\pipe\\mpv-pipe",
}
opt.read_options(o, "single_instance")

local function escape_json(str)
    if not str then return "" end
    return (str:gsub("\\", "\\\\"):gsub("\"", "\\\""))
end

local function make_absolute(path)
    if not path or path == "" then return "" end
    -- If it's a URL or protocol, keep as-is
    if path:match("^%a[%w+.-]*://") then
        return path
    end
    -- If it's already an absolute Windows path (e.g. C:\... or \\...)
    if path:match("^%a:[/\\]") or path:match("^[/\\][/\\]") then
        return path
    end
    local cwd = mp.get_property("working-directory") or ""
    return utils.join_path(cwd, path)
end

-- Allow Windows foreground activation transfer via FFI if available
local function grant_foreground(target_pid)
    local ok, ffi = pcall(require, "ffi")
    if ok and ffi then
        pcall(function()
            ffi.cdef[[
                typedef unsigned long DWORD;
                typedef int BOOL;
                BOOL AllowSetForegroundWindow(DWORD dwProcessId);
            ]]
            ffi.C.AllowSetForegroundWindow(target_pid or 0xFFFFFFFF)
        end)
    end
end

-- Primary instance focus handler
mp.register_script_message("single-instance-focus", function()
    if o.unminimize then
        mp.set_property_bool("window-minimized", false)
    end
    local was_ontop = mp.get_property_bool("ontop")
    if not was_ontop then
        mp.set_property_bool("ontop", true)
        mp.add_timeout(0.15, function()
            mp.set_property_bool("ontop", false)
        end)
    end
end)

-- Main check executed on script load
local function check_single_instance()
    local my_pid = mp.get_property_native("pid")
    local f = io.open(o.pipe_path, "r+")
    if not f then
        -- Primary instance: pipe does not exist yet (or is not ready), run normally.
        return
    end

    -- Query the IPC server for its PID to verify if it is an external instance or ourselves
    f:write('{"command": ["get_property", "pid"], "request_id": 9999}\n')
    f:flush()
    local resp = f:read("*l")
    local json = resp and utils.parse_json(resp)
    local server_pid = json and json.data

    if not server_pid or server_pid == my_pid then
        -- We connected to ourselves or server did not respond properly; continue as primary
        f:close()
        return
    end

    -- Another instance is running! We are secondary.
    grant_foreground(server_pid)

    local playlist = mp.get_property_native("playlist") or {}
    if #playlist > 0 then
        for i, item in ipairs(playlist) do
            local file_path = make_absolute(item.filename)
            local mode = (i == 1) and o.action or "append"
            local cmd = string.format('{"command": ["loadfile", "%s", "%s"]}\n', escape_json(file_path), mode)
            f:write(cmd)
        end
        f:write('{"command": ["set_property", "pause", false]}\n')
    end

    if o.unminimize then
        f:write('{"command": ["set_property", "window-minimized", false]}\n')
    end
    f:write('{"command": ["script-message", "single-instance-focus"]}\n')
    f:flush()
    f:close()

    -- Exit secondary instance immediately before video rendering or window creation
    mp.commandv("quit")
end

check_single_instance()
