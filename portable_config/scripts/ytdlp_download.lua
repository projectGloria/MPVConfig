local mp = require "mp"
local utils = require "mp.utils"

-- Prefer the official standalone yt-dlp in portable_config over PATH.
-- Update it with: .\portable_config\yt-dlp.exe -U
local ytdlp = (function()
    local local_copy = mp.command_native({"expand-path", "~~/yt-dlp.exe"})
    local fi = utils.file_info(local_copy)
    if fi and fi.is_file then return local_copy end
    return "yt-dlp"
end)()

-- Final completed downloads
local opts = { directory = "", temp_directory = "" }
require("mp.options").read_options(opts, "ytdlp_download")
local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
local download_dir = opts.directory ~= "" and opts.directory
    or utils.join_path(home, "Downloads/mpv")

-- Temporary/incomplete files
local temp_dir = opts.temp_directory ~= "" and opts.temp_directory
    or utils.join_path(download_dir, "_incomplete")

local running = false

local function strip_ytdl_prefix(url)
    if not url then return "" end
    return url:gsub("^ytdl://", "")
end

local function is_network_url(url)
    return url and url:match("^https?://") ~= nil
end

local function start_ytdlp_download()
    if running then
        mp.osd_message("yt-dlp: already running", 3)
        return
    end

    local url = strip_ytdl_prefix(mp.get_property("path", ""))

    if not is_network_url(url) then
        mp.osd_message("yt-dlp: not a network URL", 3)
        return
    end

    running = true

    local args = {
        ytdlp,

        -- Use your normal yt-dlp.conf.
        -- Do NOT use --ignore-config.

        -- Override only the output folders.
        "-P", "home:" .. download_dir,
        "-P", "temp:" .. temp_dir,

        -- Prevent playlist accidents.
        "--no-playlist",

        "--newline",

        url
    }

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = false,
        capture_stderr = false,
        args = args,
    }, function(success, result, error)
        running = false

        if result and result.killed_by_us then
            mp.osd_message("yt-dlp stopped with playback; resume later", 4)
        elseif result and result.status == 0 then
            mp.osd_message("yt-dlp finished", 3)
        else
            mp.osd_message("yt-dlp stopped/failed", 3)
        end
    end)

    mp.osd_message("yt-dlp started → " .. download_dir, 4)
end

mp.add_key_binding(nil, "download_current", start_ytdlp_download)