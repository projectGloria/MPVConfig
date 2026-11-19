-- Read the player's existing extraction result only when it belongs to this URL.
local mp = require "mp"
local utils = require "mp.utils"
local M = {}

local cached_stdout = nil
local cached_json = nil

function M.video_id(url)
    url = (url or ""):gsub("^ytdl://", "")
    local host, path = url:match("^https?://([^/]+)(/.*)$")
    if not host then return nil end
    host = host:lower()
    if host == "youtu.be" then return path:match("^/([%w_-]+)") end
    if host == "youtube.com" or host:match("%.youtube%.com$") then
        return path:match("[?&]v=([%w_-]+)")
            or path:match("^/shorts/([%w_-]+)")
    end
end

function M.get(url)
    local result = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    if type(result) ~= "table" or result.status ~= 0 or not result.stdout then return nil end
    local json
    if result.stdout == cached_stdout then
        json = cached_json
    else
        json = utils.parse_json(result.stdout)
        cached_stdout = result.stdout
        cached_json = type(json) == "table" and json or nil
    end
    if type(json) ~= "table" then return nil end
    url = (url or ""):gsub("^ytdl://", "")
    local id = M.video_id(url)
    for _, key in ipairs({"webpage_url", "original_url"}) do
        local candidate = json[key]
        if type(candidate) == "string" and
            (candidate == url or (id and M.video_id(candidate) == id)) then
            return json
        end
    end
end

-- The title to show for a yt-dlp result. Twitch live streams are the odd one:
-- yt-dlp sets `title` to "Channel (live) YYYY-MM-DD HH:MM" and puts the
-- broadcaster's actual stream title in `description`.
function M.title(json)
    if type(json) ~= "table" then return nil end
    if json.extractor_key == "TwitchStream" and type(json.description) == "string" then
        local t = (json.description:match("^%s*([^\r\n]*)") or ""):gsub("%s+$", "")
        if t ~= "" then return t end
    end
    if type(json.title) == "string" and json.title ~= "" then return json.title end
    return nil
end

return M
