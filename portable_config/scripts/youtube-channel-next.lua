-- youtube-channel-next.lua
-- When you press > on a YouTube video, loads the next video from the SAME channel.
-- Channel video list is fetched in the background as soon as a video loads,
-- so pressing > is usually instant.
--
-- FIX: Added a 3-second startup delay before spawning any yt-dlp subprocess.
-- Previously, the channel_url resolution subprocess fired immediately on
-- file-loaded, racing with the demuxer buffer fill and compounding the initial
-- network load. The delay gives the demuxer time to fill its forward buffer
-- before any background process competes for CPU and bandwidth.
--
-- Place in: portable_config/scripts/youtube-channel-next.lua

local mp    = require 'mp'
local utils = require 'mp.utils'

-- ── Config ────────────────────────────────────────────────────────────────────
-- Prefer the official standalone yt-dlp in portable_config over PATH.
-- Update it with: .\portable_config\yt-dlp.exe -U
local YTDLP = (function()
    local local_copy = mp.command_native({"expand-path", "~~/yt-dlp.exe"})
    local fi = utils.file_info(local_copy)
    if fi and fi.is_file then return local_copy end
    return "yt-dlp"
end)()
local FETCH_COUNT = 30   -- how many channel videos to fetch ahead

-- Delay (seconds) after file-loaded before spawning any yt-dlp subprocess.
-- This gives the demuxer buffer time to fill before background processes
-- compete for CPU and network bandwidth. Adjust down if your connection is
-- fast and you want quicker > key response on first press.
local FETCH_DELAY = 3.0
-- ──────────────────────────────────────────────────────────────────────────────

local metadata = dofile(mp.command_native({"expand-path", "~~/script-modules/ytdl_metadata.lua"}))
local channel_cache, fetch_in_progress = {}, {}
local current_channel, pending_fetch_timer
local generation, pending_next = 0, false

local function fetch_channel_videos(channel_url, on_done)
    if channel_cache[channel_url] then on_done(channel_cache[channel_url]); return end
    if fetch_in_progress[channel_url] then
        table.insert(fetch_in_progress[channel_url], on_done)
        return
    end
    fetch_in_progress[channel_url] = {on_done}
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = {YTDLP, "--no-warnings", "--flat-playlist", "--print", "url",
                "--playlist-end", tostring(FETCH_COUNT), channel_url:gsub("/+$", "") .. "/videos"}
    }, function(success, result)
        local waiters = fetch_in_progress[channel_url]
        fetch_in_progress[channel_url] = nil
        local urls = {}
        if success and result and result.status == 0 then
            for line in (result.stdout or ""):gmatch("[^\r\n]+") do
                if metadata.video_id(line) then table.insert(urls, line) end
            end
        end
        if #urls > 0 then channel_cache[channel_url] = urls end
        for _, callback in ipairs(waiters) do callback(channel_cache[channel_url]) end
    end)
end

local function reset_navigation()
    generation = generation + 1
    current_channel, pending_next = nil, false
    if pending_fetch_timer then pending_fetch_timer:kill(); pending_fetch_timer = nil end
end
mp.register_event("start-file", reset_navigation)
mp.register_event("end-file", reset_navigation)

local function advance(url, token)
    local channel = current_channel
    fetch_channel_videos(channel, function(urls)
        if token ~= generation or mp.get_property("path") ~= url then return end
        if not pending_next then return end
        pending_next = false
        if not urls then mp.osd_message("Could not fetch channel videos", 3); return end
        local id, index = metadata.video_id(url), 0
        for i, candidate in ipairs(urls) do
            if metadata.video_id(candidate) == id then index = i; break end
        end
        local next_index = index % #urls + 1
        if metadata.video_id(urls[next_index]) == id then
            mp.osd_message("No other channel videos available", 3)
            return
        end
        mp.commandv("loadfile", urls[next_index])
        mp.osd_message(("Channel %d / %d"):format(next_index, #urls), 2)
    end)
end

mp.register_event("file-loaded", function()
    local url, token = mp.get_property("path"), generation
    if not metadata.video_id(url) then return end
    local function resolved(channel)
        if token ~= generation or mp.get_property("path") ~= url then return end
        if not channel or not channel:match("^https?://") then
            if pending_next then mp.osd_message("Could not resolve channel", 3) end
            pending_next = false
            return
        end
        current_channel = channel
        if pending_next then advance(url, token)
        else fetch_channel_videos(channel, function() end) end
    end
    pending_fetch_timer = mp.add_timeout(FETCH_DELAY, function()
        pending_fetch_timer = nil
        if token ~= generation or mp.get_property("path") ~= url then return end
        local json = metadata.get(url)
        if json and type(json.channel_url) == "string" and json.channel_url ~= "" then
            resolved(json.channel_url)
            return
        end
        mp.command_native_async({
            name = "subprocess", capture_stdout = true, playback_only = false,
            args = {YTDLP, "--no-warnings", "--no-playlist", "--print", "channel_url",
                    -- Parens truncate gsub's (string, count) pair; as the last table item it would otherwise
                    -- append the match count as a bogus extra argument to yt-dlp.
                    "--no-download", (url:gsub("^ytdl://", ""))}
        }, function(success, result)
            local channel = success and result and result.status == 0 and
                (result.stdout or ""):gsub("%s+$", "") or nil
            resolved(channel)
        end)
    end)
end)

mp.register_script_message("yt-channel-next", function()
    local url = mp.get_property("path")
    if not metadata.video_id(url) then mp.command("playlist-next"); return end
    -- Coalesce repeated presses while resolving/fetching into one navigation.
    if pending_next then return end
    pending_next = true
    if current_channel then advance(url, generation)
    else mp.osd_message("Resolving channel...", 3) end
end)
