-- stream_title.lua
-- Shows the real stream title where yt-dlp's `title` is a placeholder.
-- Twitch live: yt-dlp reports "Channel (live) date time" as the title and
-- the broadcaster's title as the description (see ytdl_metadata.title).
-- Sets file-local force-media-title, so the OSD, window title and Tethys all
-- pick it up and mpv drops it on the next file by itself.

local mp = require "mp"

local metadata = dofile(mp.command_native({"expand-path", "~~/script-modules/ytdl_metadata.lua"}))

mp.register_event("file-loaded", function()
    if not mp.get_property_bool("demuxer-via-network", false) then return end
    local json = metadata.get(mp.get_property("path", ""))
    local title = metadata.title(json)
    if title and title ~= json.title then
        mp.set_property("file-local-options/force-media-title", title)
    end
end)
