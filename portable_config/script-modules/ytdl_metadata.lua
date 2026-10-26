-- Read the player's existing extraction result only when it belongs to this URL.
local mp = require "mp"
local utils = require "mp.utils"
local M = {}

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
    local json = utils.parse_json(result.stdout)
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

return M
