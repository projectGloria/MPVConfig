-- twitch_points.lua
-- Earns Twitch channel points while you watch a live Twitch stream in mpv.
--
-- WHY THIS EXISTS
-- yt-dlp only fetches the video. Twitch awards channel points from two things
-- the website does while you watch, and mpv does neither by default:
--   1. a "minute-watched" report to Twitch's analytics endpoint every minute
--      (passive points, watch streaks);
--   2. clicking the bonus chest that appears every ~15 minutes.
-- This script does both, ONLY while a live twitch.tv stream is open in mpv and
-- NOT paused. It never watches channels you are not watching.
--
-- LOGIN
-- Uses the `auth-token` cookie of your logged-in Firefox session (the same
-- profile cookies_auto uses). It is read directly from Firefox's cookies.sqlite
-- with Windows' built-in winsqlite3.dll through LuaJIT FFI: a temporary copy
-- is opened, so Firefox can stay running, and the copy is deleted afterwards.
-- You can instead paste the token into `auth_token=` in the options file.
-- The token is only ever sent to twitch.tv hosts.
--
-- CAVEAT
-- This talks to Twitch's private website API. Twitch changes it without notice;
-- if points stop arriving, press Alt+p to see the last error. The GQL query
-- hashes are options so they can be updated without editing this file.
--
-- Keybind: Alt+p shows status (channel, balance, minutes reported, last error).
-- Options: portable_config/script-opts/twitch_points.conf

local mp    = require "mp"
local utils = require "mp.utils"
local msg   = require "mp.msg"
local opt   = require "mp.options"

local o = {
    enabled = true,
    -- Paste the `auth-token` cookie value here to skip reading Firefox.
    auth_token = "",
    -- Firefox profile directory name; empty = newest cookies.sqlite.
    firefox_profile = "",
    claim_bonus = true,
    interval = 60,              -- seconds between minute-watched reports
    notify = true,              -- OSD message when a bonus is claimed
    -- Twitch web client. The Firefox token is bound to it, so do not change
    -- this unless auth_token comes from a different client.
    client_id = "kimne78kx3ncx6brgo4mv6wki5h1ko",
    hash_stream_info = "198492e0857f6aedead9665c81c5a06d67b25b58034649687124083ff288597d",
    hash_points_context = "7fe050e3761eb2cf258d70ee1a21cbd76fa8cf3d7e7b12fc437e7029d446b5e3",
    hash_claim = "46aaeebe02c99afdf4fc97c7c0cba964124bf6b0af229395f1f6d1feed05b3d0",
}
opt.read_options(o, "twitch_points")

local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
local GQL = "https://gql.twitch.tv/gql"

-- ─────────────────────────────────────────────────────────────────────────────
-- STATE
-- ─────────────────────────────────────────────────────────────────────────────
local session = {                 -- survives file changes
    token = nil, device_id = nil, token_checked = false,
    user_id = nil, user_login = nil,
    spade_url = nil, client_version = nil,
    session_id = nil,
}
local cur = nil                   -- current watch: {gen, login, channel_id, broadcast_id, ...}
local gen = 0                     -- bumped on every start-file; stale callbacks compare it
local tick_timer = nil
local last_error = nil

local function random_hex(n)
    local t = {}
    for i = 1, n do t[i] = ("%x"):format(math.random(0, 15)) end
    return table.concat(t)
end
math.randomseed(os.time())
session.session_id = random_hex(16)

-- Shared with osc_tethys.lua (points element in the bottom bar).
local function publish()
    if cur and cur.active then
        mp.set_property_native("user-data/twitch_points", {
            active = true, channel = cur.login, balance = cur.balance,
            claimed_at = cur.claimed_at,
        })
    else
        mp.set_property_native("user-data/twitch_points", {active = false})
    end
end

local function fail(text)
    last_error = text
    msg.warn(text)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- URL → channel login (live channel pages only)
-- ─────────────────────────────────────────────────────────────────────────────
local RESERVED = {
    videos=1, clips=1, directory=1, settings=1, search=1, downloads=1, jobs=1,
    turbo=1, subscriptions=1, inventory=1, drops=1, wallet=1, friends=1, p=1,
    login=1, signup=1, messages=1, moderator=1, u=1, embed=1, broadcast=1,
}

local function channel_from_url(url)
    if type(url) ~= "string" then return nil end
    url = url:gsub("^ytdl://", "")
    local host, rest = url:match("^https?://([^/?#]+)(.*)$")
    if not host then return nil end
    host = host:lower():gsub(":%d+$", "")
    if host ~= "twitch.tv" and host:sub(-10) ~= ".twitch.tv" then return nil end

    if host == "player.twitch.tv" then
        local ch = rest:match("[?&]channel=([%w_]+)")
        return ch and ch:lower() or nil
    end
    local path = rest:match("^([^?#]*)") or ""
    local a, b = path:match("^/([^/]+)/?([^/]*)")
    if a == "popout" then a, b = b, "" end
    if not a or (b ~= nil and b ~= "") then return nil end   -- /x/videos etc.
    a = a:lower()
    if RESERVED[a] or not a:match("^[%w_]+$") then return nil end
    return a
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FIREFOX auth-token (LuaJIT FFI + winsqlite3)
-- ─────────────────────────────────────────────────────────────────────────────
local function profile_dir()
    local root = (os.getenv("APPDATA") or "") .. "/Mozilla/Firefox/Profiles"
    if o.firefox_profile ~= "" then
        local p = root .. "/" .. o.firefox_profile
        local fi = utils.file_info(p .. "/cookies.sqlite")
        if fi and fi.is_file then return p end
        msg.warn("firefox_profile not found, using newest: " .. o.firefox_profile)
    end
    local names = utils.readdir and utils.readdir(root, "dirs")
    if not names then return nil end
    local best, best_mtime = nil, -1
    for _, name in ipairs(names) do
        local fi = utils.file_info(root .. "/" .. name .. "/cookies.sqlite")
        if fi and fi.is_file and fi.mtime > best_mtime then
            best, best_mtime = root .. "/" .. name, fi.mtime
        end
    end
    return best
end

local function copy_file(src, dst)
    local f = io.open(src, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    local g = io.open(dst, "wb")
    if not g then return false end
    g:write(data)
    g:close()
    return true
end

local sqlite_lib = nil
local function sqlite()
    if sqlite_lib ~= nil then return sqlite_lib or nil end
    local ok, ffi = pcall(require, "ffi")
    if not ok then sqlite_lib = false; return nil end
    ok = pcall(ffi.cdef, [[
        int sqlite3_open_v2(const char *f, void **db, int flags, const char *vfs);
        int sqlite3_prepare_v2(void *db, const char *sql, int n, void **st, const char **tail);
        int sqlite3_step(void *st);
        const unsigned char *sqlite3_column_text(void *st, int col);
        int sqlite3_finalize(void *st);
        int sqlite3_close(void *db);
    ]])
    local lib
    if ok then ok, lib = pcall(ffi.load, "winsqlite3") end
    sqlite_lib = ok and {ffi = ffi, lib = lib} or false
    return sqlite_lib or nil
end

-- Returns { ["auth-token"]=..., unique_id=... } from the twitch.tv cookies.
local function read_firefox_cookies()
    local prof = profile_dir()
    if not prof then return nil, "no Firefox profile with cookies.sqlite" end
    local s = sqlite()
    if not s then return nil, "LuaJIT FFI / winsqlite3.dll unavailable" end
    local ffi, lib = s.ffi, s.lib

    local tmp = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "/mpv-twitch-points-"
                .. random_hex(8) .. ".sqlite"
    if not copy_file(prof .. "/cookies.sqlite", tmp) then
        return nil, "could not copy Firefox cookies.sqlite"
    end
    copy_file(prof .. "/cookies.sqlite-wal", tmp .. "-wal")   -- recent writes

    local out = {}
    local db = ffi.new("void*[1]")
    if lib.sqlite3_open_v2(tmp, db, 2 --[[READWRITE]], nil) == 0 then
        local st = ffi.new("void*[1]")
        local sql = "SELECT name, value FROM moz_cookies WHERE name IN "
                 .. "('auth-token','unique_id') AND (host='.twitch.tv' OR host='twitch.tv' "
                 .. "OR host='www.twitch.tv') ORDER BY lastAccessed ASC"
        if lib.sqlite3_prepare_v2(db[0], sql, -1, st, nil) == 0 then
            while lib.sqlite3_step(st[0]) == 100 --[[ROW]] do
                local n, v = lib.sqlite3_column_text(st[0], 0), lib.sqlite3_column_text(st[0], 1)
                if n ~= nil and v ~= nil then out[ffi.string(n)] = ffi.string(v) end
            end
            lib.sqlite3_finalize(st[0])
        end
        lib.sqlite3_close(db[0])
    end
    os.remove(tmp); os.remove(tmp .. "-wal"); os.remove(tmp .. "-shm")
    return out
end

local function ensure_token()
    if session.token_checked then return session.token end
    session.token_checked = true
    if o.auth_token ~= "" then
        session.token = o.auth_token
    else
        local ck, err = read_firefox_cookies()
        if not ck then
            fail("Twitch points: " .. err)
        elseif not ck["auth-token"] then
            fail("Twitch points: not logged in to twitch.tv in Firefox")
        else
            session.token = ck["auth-token"]
            session.device_id = ck.unique_id
        end
    end
    session.device_id = session.device_id or random_hex(32)
    return session.token
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HTTP via curl.exe (ships with Windows 10+). Bodies carry no secrets (the
-- token is only in a header), so they are passed as an argument; mpv's
-- stdin_data did not reach curl on Windows.
-- ─────────────────────────────────────────────────────────────────────────────
local function http(req, cb)
    local args = {"curl", "-sS", "--compressed", "--max-time", "20",
                  "-A", UA, "-w", "\n%{http_code}"}
    for _, h in ipairs(req.headers or {}) do
        args[#args + 1] = "-H"; args[#args + 1] = h
    end
    if req.body then
        args[#args + 1] = "--data-binary"; args[#args + 1] = req.body
    end
    args[#args + 1] = req.url
    mp.command_native_async({
        name = "subprocess", args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true,
    }, function(ok, res)
        local out = (ok and res and res.stdout) or ""
        local body, code = out:match("^(.*)\n(%d%d%d)%s*$")
        cb(tonumber(code) or 0, body or out, res and res.stderr)
    end)
end

local function gql(op, hash, variables, cb)
    local headers = {
        "Authorization: OAuth " .. session.token,
        "Client-Id: " .. o.client_id,
        "Client-Session-Id: " .. session.session_id,
        "X-Device-Id: " .. session.device_id,
        "Content-Type: text/plain;charset=UTF-8",
        "Origin: https://www.twitch.tv",
        "Referer: https://www.twitch.tv/",
    }
    if session.client_version then
        headers[#headers + 1] = "Client-Version: " .. session.client_version
    end
    local body = utils.format_json({
        operationName = op, variables = variables,
        extensions = {persistedQuery = {version = 1, sha256Hash = hash}},
    })
    http({url = GQL, headers = headers, body = body}, function(code, text)
        local data = utils.parse_json(text or "")
        if code ~= 200 or type(data) ~= "table" then
            cb(nil, ("%s: HTTP %d %s"):format(op, code, (text or ""):sub(1, 160)))
            return
        end
        if type(data.errors) == "table" and data.errors[1] then
            cb(nil, op .. ": " .. tostring(data.errors[1].message))
            return
        end
        cb(data.data or {})
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SETUP STEPS (each async; every callback checks it is still for `g`)
-- ─────────────────────────────────────────────────────────────────────────────
local function validate(g, cb)
    if session.user_id then return cb(true) end
    http({url = "https://id.twitch.tv/oauth2/validate",
          headers = {"Authorization: OAuth " .. session.token}}, function(code, text)
        if g ~= gen then return end
        local data = utils.parse_json(text or "")
        if code ~= 200 or type(data) ~= "table" or not data.user_id then
            fail(("Twitch points: login token rejected (HTTP %d) -- log in again in Firefox"):format(code))
            session.token_checked, session.token = false, nil  -- re-read next file
            return cb(false)
        end
        session.user_id, session.user_login = tostring(data.user_id), data.login
        cb(true)
    end)
end

-- spade_url (analytics endpoint) and the site's build id, from the channel page.
local function discover_spade(g, login, cb)
    if session.spade_url then return cb(true) end
    http({url = "https://www.twitch.tv/" .. login}, function(code, page)
        if g ~= gen then return end
        session.client_version = session.client_version
            or page:match('__twilightBuildID%s*=%s*"([%x%-]+)"')
        local settings = page:match('(https://static%.twitchcdn%.net/config/settings[^"\']-%.js)')
                      or page:match('(https://assets%.twitch%.tv/config/settings[^"\']-%.js)')
        if not settings then
            fail(("Twitch points: settings script not found on channel page (HTTP %d)"):format(code))
            return cb(false)
        end
        http({url = settings}, function(_, js)
            if g ~= gen then return end
            local spade = js:match('"spade_url":"([^"]+)"')
            if not spade then
                fail("Twitch points: spade_url not found in settings script")
                return cb(false)
            end
            session.spade_url = spade:gsub("\\/", "/")
            cb(true)
        end)
    end)
end

local function stream_info(g, login, cb)
    gql("VideoPlayerStreamInfoOverlayChannel", o.hash_stream_info, {channel = login},
    function(data, err)
        if g ~= gen then return end
        if not data then fail("Twitch points: " .. err); return cb(false) end
        local user = data.user
        if type(user) ~= "table" or not user.id then
            fail("Twitch points: channel not found: " .. login); return cb(false)
        end
        if type(user.stream) ~= "table" or not user.stream.id then
            fail("Twitch points: " .. login .. " is offline"); return cb(false)
        end
        cur.channel_id, cur.broadcast_id = tostring(user.id), tostring(user.stream.id)
        local game = user.stream.game
        if type(game) == "table" then cur.game, cur.game_id = game.name, game.id end
        cb(true)
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PER-MINUTE WORK
-- ─────────────────────────────────────────────────────────────────────────────
local function b64(s)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return ((s:gsub(".", function(x)
        local r, b = "", x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return chars:sub(c + 1, c + 1)
    end) .. ({"", "==", "="})[#s % 3 + 1])
end

local function urlencode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function send_minute_watched(g)
    local props = {
        channel_id = cur.channel_id, broadcast_id = cur.broadcast_id,
        player = "site", user_id = session.user_id, live = true, channel = cur.login,
        game = cur.game, game_id = cur.game_id,
    }
    local payload = utils.format_json({{event = "minute-watched", properties = props}})
    http({url = session.spade_url,
          headers = {"Content-Type: application/x-www-form-urlencoded"},
          body = "data=" .. urlencode(b64(payload))}, function(code)
        if g ~= gen then return end
        if code == 204 or code == 200 then
            cur.minutes = cur.minutes + 1
        else
            fail(("Twitch points: minute-watched rejected (HTTP %d)"):format(code))
        end
    end)
end

local function check_points(g)
    gql("ChannelPointsContext", o.hash_points_context, {channelLogin = cur.login},
    function(data, err)
        if g ~= gen then return end
        if not data then fail("Twitch points: " .. err); return end
        local cp = data.community and data.community.channel
                   and data.community.channel.self and data.community.channel.self.communityPoints
        if type(cp) ~= "table" then return end   -- channel without points
        cur.balance = cp.balance
        publish()
        local claim = cp.availableClaim
        if not (o.claim_bonus and type(claim) == "table" and claim.id) then return end
        if cur.claimed[claim.id] then return end
        cur.claimed[claim.id] = true
        gql("ClaimCommunityPoints", o.hash_claim,
            {input = {channelID = cur.channel_id, claimID = claim.id}},
        function(res, cerr)
            if g ~= gen then return end
            local r = res and res.claimCommunityPoints
            if not res or (type(r) == "table" and type(r.error) == "table") then
                cur.claimed[claim.id] = nil   -- retry next minute
                fail("Twitch points: bonus claim failed: "
                     .. (cerr or tostring(r.error.code)))
                return
            end
            cur.bonuses = cur.bonuses + 1
            if type(r) == "table" and type(r.currentPoints) == "number" then
                cur.balance = r.currentPoints
            end
            cur.claimed_at = mp.get_time()
            publish()
            msg.info("claimed bonus on " .. cur.login)
            if o.notify then mp.osd_message("Twitch: bonus points claimed", 2) end
        end)
    end)
end

local function schedule(g)
    tick_timer = mp.add_timeout(o.interval, function()
        if g ~= gen or not cur then return end
        if not mp.get_property_native("pause", false) then
            send_minute_watched(g)
        end
        check_points(g)
        schedule(g)
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- LIFECYCLE
-- ─────────────────────────────────────────────────────────────────────────────
local function stop()
    gen = gen + 1
    cur = nil
    if tick_timer then tick_timer:kill(); tick_timer = nil end
    publish()
end

mp.register_event("start-file", stop)
mp.register_event("end-file", stop)

mp.register_event("file-loaded", function()
    if not o.enabled then return end
    local login = channel_from_url(mp.get_property("path"))
    if not login then return end
    stop()
    local g = gen
    cur = {gen = g, login = login, minutes = 0, bonuses = 0, claimed = {}}
    if not ensure_token() then return end

    validate(g, function(ok)
        if not ok then return end
        stream_info(g, login, function(ok2)
            if not ok2 then return end
            discover_spade(g, login, function(ok3)
                if not ok3 then return end
                last_error = nil
                cur.active = true
                publish()
                msg.info(("earning points on %s as %s"):format(login, session.user_login or "?"))
                check_points(g)
                schedule(g)
            end)
        end)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- STATUS  (Alt+p)
-- ─────────────────────────────────────────────────────────────────────────────
mp.add_key_binding(nil, "twitch-points-status", function()
    local lines = {}
    if not o.enabled then
        lines[1] = "Twitch points: disabled"
    elseif not cur then
        lines[1] = "Twitch points: not watching a live Twitch channel"
    else
        lines[#lines + 1] = ("Twitch points: %s%s"):format(cur.login,
            cur.active and "" or " (not active)")
        lines[#lines + 1] = "Account: " .. (session.user_login or "?")
        lines[#lines + 1] = "Balance: " .. (cur.balance and tostring(cur.balance) or "?")
        lines[#lines + 1] = ("Minutes reported: %d   Bonuses claimed: %d")
                            :format(cur.minutes, cur.bonuses)
    end
    if last_error then lines[#lines + 1] = "Last error: " .. last_error end
    mp.osd_message(table.concat(lines, "\n"), 6)
    msg.info(table.concat(lines, " | "))
end)

-- Exposed for tests only.
return { channel_from_url = channel_from_url, b64 = b64 }
