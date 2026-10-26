-- cookies_auto.lua
-- Automatically hands yt-dlp your browser cookies, with a safety net.
--
-- WHY THIS EXISTS
-- YouTube increasingly refuses anonymous extraction ("Sign in to confirm you're
-- not a bot", "Failed to extract any player response"). mpv surfaces that as
-- ytdl_hook's subprocess failing, which quality-menu reports as
-- "fetching formats failed..." and which leaves the file unplayable.
-- Passing cookies from a logged-in browser session is the usual fix.
--
-- WHY NOT JUST A LINE IN mpv.conf
-- A bare `ytdl-raw-options-append=cookies-from-browser=firefox` is one line, but
-- it fails CLOSED: if cookie extraction breaks for any reason (profile renamed,
-- database locked, browser uninstalled) yt-dlp exits non-zero and NOTHING plays,
-- including the sites that never needed cookies. That trades an intermittent
-- failure for a total one. This script fails OPEN instead: if a cookie-enabled
-- attempt fails, it retries the same URL once with cookies off.
--
-- WHY FIREFOX
-- Chrome 127+ encrypts its cookie store with App-Bound Encryption. On this
-- machine Chrome, Edge and Brave all have `app_bound_encrypted_key` set in their
-- "Local State", which yt-dlp cannot decrypt on Windows -- it reads the database
-- and yields no usable cookies. Firefox stores cookies.sqlite unencrypted and
-- works. That is why the default browser here is firefox, not your daily driver.
--
-- Keybind: Alt+c shows the current cookie source.
-- Options: portable_config/script-opts/cookies_auto.conf

local mp    = require "mp"
local utils = require "mp.utils"
local msg   = require "mp.msg"
local opt   = require "mp.options"

local o = {
    enabled = true,

    -- auto | firefox | chrome | edge | brave | vivaldi | opera | chromium | none
    -- "auto" means: use `browser_priority` below, first one whose cookie store
    -- actually exists on disk.
    browser = "auto",
    browser_priority = "firefox",

    -- Firefox profile directory name, e.g. "example.default-release".
    -- Empty = let yt-dlp choose (it picks the most recently modified
    -- cookies.sqlite, which is usually but not always the one you are logged
    -- into). Pinning a name is more predictable.
    firefox_profile = "",

    -- Which URLs get cookies attached.
    --   youtube = youtube.com / youtu.be only  (recommended)
    --   all     = every network URL
    -- Cookies are domain-scoped by yt-dlp, so "all" does not leak your YouTube
    -- session to unrelated hosts -- but it does read the cookie database on
    -- every single stream, which is slower and pointless for sites that work
    -- anonymously.
    domains = "youtube",

    -- If a cookie-enabled load fails, retry the same URL once without cookies.
    fallback_on_failure = true,

    notify = true,
}
opt.read_options(o, "cookies_auto")

-- ─────────────────────────────────────────────────────────────────────────────
-- BROWSER COOKIE STORE DETECTION
-- ─────────────────────────────────────────────────────────────────────────────
local APPDATA  = os.getenv("APPDATA")  or ""
local LOCALAPP = os.getenv("LOCALAPPDATA") or ""

local function dir_exists(path)
    local fi = utils.file_info(path)
    return fi ~= nil and fi.is_dir
end

local function file_exists(path)
    local fi = utils.file_info(path)
    return fi ~= nil and fi.is_file
end

-- Mirrors yt-dlp's own Firefox selection: newest cookies.sqlite wins.
local function newest_firefox_profile()
    local root = APPDATA .. "/Mozilla/Firefox/Profiles"
    if not dir_exists(root) then return nil end
    local names = utils.readdir(root, "dirs")
    if not names then return nil end

    local best, best_mtime = nil, -1
    for _, name in ipairs(names) do
        local fi = utils.file_info(root .. "/" .. name .. "/cookies.sqlite")
        if fi and fi.is_file and fi.mtime > best_mtime then
            best, best_mtime = name, fi.mtime
        end
    end
    return best
end

local function firefox_available()
    if o.firefox_profile ~= "" then
        local p = APPDATA .. "/Mozilla/Firefox/Profiles/" .. o.firefox_profile
        if file_exists(p .. "/cookies.sqlite") then
            return "firefox:" .. o.firefox_profile
        end
        msg.warn("configured firefox_profile not found, falling back to newest: "
                 .. o.firefox_profile)
    end
    if newest_firefox_profile() then return "firefox" end
    return nil
end

-- Chromium-family stores. Detected for completeness, but see the App-Bound
-- Encryption note at the top of this file before relying on any of them.
local CHROMIUM = {
    chrome   = LOCALAPP .. "/Google/Chrome/User Data",
    edge     = LOCALAPP .. "/Microsoft/Edge/User Data",
    brave    = LOCALAPP .. "/BraveSoftware/Brave-Browser/User Data",
    vivaldi  = LOCALAPP .. "/Vivaldi/User Data",
    chromium = LOCALAPP .. "/Chromium/User Data",
    opera    = APPDATA  .. "/Opera Software/Opera Stable",
}

local function chromium_available(name)
    local base = CHROMIUM[name]
    if not base or not dir_exists(base) then return nil end
    if file_exists(base .. "/Default/Network/Cookies")
       or file_exists(base .. "/Default/Cookies") then
        return name
    end
    return nil
end

local function detect_browser(name)
    if name == "firefox" then return firefox_available() end
    if CHROMIUM[name] then return chromium_available(name) end
    return nil
end

-- Resolved once, lazily, then cached for the session.
local cookie_spec       = nil
local cookie_spec_ready = false

local function resolve_cookie_spec()
    if cookie_spec_ready then return cookie_spec end
    cookie_spec_ready = true

    if not o.enabled or o.browser == "none" then
        cookie_spec = nil
        return nil
    end

    if o.browser ~= "auto" then
        cookie_spec = detect_browser(o.browser)
        if not cookie_spec then
            msg.warn(("browser=%s selected but no cookie store found for it")
                     :format(o.browser))
        end
    else
        for name in o.browser_priority:gmatch("[^,%s]+") do
            local spec = detect_browser(name)
            if spec then cookie_spec = spec break end
        end
    end

    if cookie_spec then
        msg.info("cookie source: " .. cookie_spec)
    else
        msg.info("no usable browser cookie store found; continuing without cookies")
    end
    return cookie_spec
end

-- ─────────────────────────────────────────────────────────────────────────────
-- APPLY / REMOVE ON ytdl-raw-options
-- ─────────────────────────────────────────────────────────────────────────────
local applied_value = nil   -- exact string currently appended, or nil

local function cookies_on(spec)
    if applied_value then return end
    applied_value = "cookies-from-browser=" .. spec
    mp.commandv("change-list", "ytdl-raw-options", "append", applied_value)
    msg.verbose("cookies ON  -> " .. applied_value)
end

local function cookies_off()
    if not applied_value then return end
    -- ytdl-raw-options is a KEY/VALUE list: "remove" matches on the KEY alone.
    -- Passing "key=value" here silently does nothing, which would leave cookies
    -- attached to every subsequent URL and make the fallback below a no-op.
    mp.commandv("change-list", "ytdl-raw-options", "remove", "cookies-from-browser")
    msg.verbose("cookies OFF -> " .. applied_value)
    applied_value = nil
end

local function is_network(url)
    return url and url:match("^%a[%w+.-]*://") ~= nil
end

local function wants_cookies(url)
    if not is_network(url) then return false end
    if o.domains == "all" then return true end
    return url:match("youtube%.com") ~= nil
        or url:match("youtu%.be")    ~= nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HOOK: runs before ytdl_hook (which registers on_load at priority 10)
-- ─────────────────────────────────────────────────────────────────────────────
local no_cookie_retry = {}   -- url -> true, set after a cookie attempt failed

mp.add_hook("on_load", 8, function()
    local url = mp.get_property("stream-open-filename") or mp.get_property("path")
    if not url then return end
    url = url:gsub("^ytdl://", "")

    if no_cookie_retry[url] then
        cookies_off()
        return
    end

    if not wants_cookies(url) then
        cookies_off()
        return
    end

    local spec = resolve_cookie_spec()
    if spec then cookies_on(spec) else cookies_off() end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- FALLBACK: a failed cookie-enabled extraction retries once without cookies,
-- so a broken cookie database can never make a playable URL unplayable.
-- Same signal quality-menu.lua watches.
-- ─────────────────────────────────────────────────────────────────────────────
-- Pull the first real "ERROR:" line out of yt-dlp's stderr. This is the single
-- most useful thing to surface: mpv otherwise reports only "failed", and
-- quality-menu only says "fetching formats failed...", neither of which tells
-- you whether the cause was cookies, geo-blocking, a stale session, or YouTube
-- simply being unhappy that minute.
local function ytdl_error_line(res)
    local err = res and res.stderr or ""
    if err == "" then return res and res.error_string or "unknown error" end
    for line in err:gmatch("[^\r\n]+") do
        local m = line:match("^%s*ERROR:%s*(.+)$")
        if m then return m end
    end
    return (err:match("([^\r\n]+)")) or "unknown error"
end

mp.observe_property("user-data/mpv/ytdl/json-subprocess-result", "native",
function(_, res)
    if not res or res.status == 0 then return end

    local reason = ytdl_error_line(res)
    msg.warn("yt-dlp failed: " .. reason)

    if not o.fallback_on_failure or not applied_value then
        -- Nothing to retry: report the real cause rather than staying silent.
        if o.notify then mp.osd_message("yt-dlp: " .. reason, 5) end
        return
    end

    local url = (mp.get_property("path") or ""):gsub("^ytdl://", "")
    if url == "" or no_cookie_retry[url] then return end

    no_cookie_retry[url] = true
    msg.warn("retrying once without cookies")
    if o.notify then
        mp.osd_message("Retrying without cookies\n" .. reason, 3)
    end
    cookies_off()
    mp.commandv("loadfile", url, "replace")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- STATUS  (Alt+c)
-- ─────────────────────────────────────────────────────────────────────────────
mp.add_key_binding(nil, "cookies-status", function()
    local spec = resolve_cookie_spec()
    local url  = (mp.get_property("path") or ""):gsub("^ytdl://", "")
    local lines = {
        "Cookies: " .. (spec or "none available"),
        "Scope:   " .. o.domains,
        "Active:  " .. (applied_value and "yes" or "no"),
    }
    if no_cookie_retry[url] then
        lines[#lines + 1] = "Note:    cookies disabled for this URL after a failure"
    end
    mp.osd_message(table.concat(lines, "\n"), 5)
    msg.info(table.concat(lines, " | "))
end)
