-- clipboard.lua
-- Loads a URL or file path from the clipboard into the CURRENT mpv window.
-- Triggered via input.conf: Ctrl+v → script-message clipboard-paste
--
-- Behaviour:
--   • Strips all known tracking garbage (si, pp, fbclid, utm_*, etc.)
--   • Detects YouTube/generic ?t= / ?start= timestamp → strips from URL,
--     stores the clean base URL, then seeks AFTER the file has loaded.
--   • History deduplication works on the clean base URL (no timestamp drift).
--   • All paste notifications appear CENTERED on screen (both axes).
--
-- Paste is MANUAL ONLY. The clipboard is read when you press Ctrl+v and at no
-- other time -- there is no focus watcher, no polling, and no "link detected"
-- prompt. Nothing in this script touches the clipboard on its own.
--
-- Clipboard access uses mpv's NATIVE clipboard support (0.40+): the
-- `clipboard/text` property, served by the built-in win32 backend. This
-- replaced the `powershell -Command Get-Clipboard` shell-out that used to run
-- synchronously on the player thread for every Ctrl+v.

local mp = require 'mp'

-- ─────────────────────────────────────────────────────────────────────────────
-- CENTERED OSD OVERLAY
-- Uses a fixed 1920×1080 coordinate space so \pos(960,540) is always center,
-- regardless of the actual video resolution. mpv scales the overlay to fit.
-- ─────────────────────────────────────────────────────────────────────────────
local overlay       = mp.create_osd_overlay("ass-events")
overlay.res_x       = 1920
overlay.res_y       = 1080
local overlay_timer = nil

local FONT     = "Montserrat ExtraBold"
local CX, CY   = 960, 540   -- screen center in overlay coordinate space

-- Dismiss any active overlay immediately (used before showing a new one)
local function overlay_clear()
    if overlay_timer then
        overlay_timer:kill()
        overlay_timer = nil
    end
    overlay:remove()
end

-- Show a one- or two-line message centered on screen.
-- line1  : primary text  (larger, white)
-- line2  : secondary text (smaller, grey) — pass nil to omit
-- duration : seconds before auto-dismiss
local function show_center(line1, line2, duration)
    overlay_clear()

    local body
    if line2 then
        body = string.format(
            "{\\an5\\pos(%d,%d)\\fn%s\\fs48\\bord2.5\\1c&HFFFFFF&\\3c&H000000&}%s" ..
            "\\N{\\fn%s\\fs40\\bord1.5\\1c&HBBBBBB&\\3c&H000000&}%s",
            CX, CY, FONT, line1, FONT, line2
        )
    else
        body = string.format(
            "{\\an5\\pos(%d,%d)\\fn%s\\fs21\\bord2.5\\1c&HFFFFFF&\\3c&H000000&}%s",
            CX, CY, FONT, line1
        )
    end

    overlay.data = body
    overlay:update()

    overlay_timer = mp.add_timeout(duration, function()
        overlay:remove()
        overlay_timer = nil
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- URL DISPLAY HELPER
-- Truncates long URLs to a readable domain + ellipsis for on-screen display.
-- The full URL is still passed to mpv/yt-dlp — only the display string is cut.
-- ─────────────────────────────────────────────────────────────────────────────
local function display_url(url)
    if #url <= 55 then return url end
    local domain = url:match("^https?://([^/]+)") or ""
    return domain .. "/…"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TIMESTAMP PARSER
-- Handles all YouTube timestamp formats:
--   ?t=120        → plain seconds
--   ?t=120s       → seconds with suffix
--   ?t=2m30s      → minutes + seconds
--   ?t=1h20m30s   → hours + minutes + seconds
--   ?start=90     → alternate param name
-- Returns: number (seconds) or nil
-- ─────────────────────────────────────────────────────────────────────────────
local function extract_timestamp(url)
    local raw = url:match("[?&]t=([^&]+)") or url:match("[?&]start=([^&]+)")
    if not raw then return nil end

    -- floor: "%d" in string.format errors on non-integral numbers like ?t=90.5
    local plain = tonumber(raw)
    if plain then return math.floor(plain) end

    local s_only = raw:match("^(%d+)s$")
    if s_only then return tonumber(s_only) end

    local h, m, s = raw:match("^(%d+)h(%d+)m(%d+)s$")
    if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end

    local hh, mm = raw:match("^(%d+)h(%d+)m$")
    if hh then return tonumber(hh) * 3600 + tonumber(mm) * 60 end

    local m2, s2 = raw:match("^(%d+)m(%d+)s$")
    if m2 then return tonumber(m2) * 60 + tonumber(s2) end

    local m3 = raw:match("^(%d+)m$")
    if m3 then return tonumber(m3) * 60 end

    local s3 = raw:match("^(%d+)s$")
    if s3 then return tonumber(s3) end

    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- URL CLEANER
-- Returns: clean_url (string), timestamp_secs (number or nil)
--
-- Pass 1 – extract timestamp params (t, start); we seek manually.
-- Pass 2 – strip tracking garbage (si, pp, fbclid, utm_*).
-- ─────────────────────────────────────────────────────────────────────────────
local function clean_url(url)
    if not url:match("^https?://") then
        return url, nil
    end

    local timestamp_secs = extract_timestamp(url)

    local strip_list = { "si", "pp", "fbclid", "t", "start", "list", "index" }
    for _, param in ipairs(strip_list) do
        url = url:gsub("%?" .. param .. "=[^&]*&", "?")
        url = url:gsub("%?" .. param .. "=[^&]*$", "")
        url = url:gsub("&" .. param .. "=[^&]*", "")
    end

    url = url:gsub("%?utm_[^=]+=[^&]*&", "?")
    url = url:gsub("%?utm_[^=]+=[^&]*$", "")
    url = url:gsub("&utm_[^=]+=[^&]*", "")

    return url, timestamp_secs
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CLIPBOARD PASTE HANDLER
-- ─────────────────────────────────────────────────────────────────────────────
local pending_seek, pending_seek_timer, pending_url

local function cancel_pending_seek()
    if pending_seek then mp.unregister_event(pending_seek) end
    if pending_seek_timer then pending_seek_timer:kill() end
    pending_seek, pending_seek_timer, pending_url = nil, nil, nil
end

mp.register_event("start-file", function()
    if pending_url and mp.get_property("path") ~= pending_url then cancel_pending_seek() end
end)
mp.register_event("end-file", function()
    -- Replacing the previous file also emits end-file before the new URL starts.
    if pending_seek_timer then cancel_pending_seek() end
end)

local function play_url(raw)
    cancel_pending_seek()
    local final_url, timestamp_secs = clean_url(raw)
    local durl = display_url(final_url)

    if timestamp_secs and timestamp_secs > 0 then
        -- Register a ONE-SHOT file-loaded listener to seek after stream is ready.
        pending_url = final_url
        pending_seek = function()
            mp.unregister_event(pending_seek)
            pending_seek = nil
            if mp.get_property("path") ~= final_url then
                cancel_pending_seek()
                return
            end
            pending_seek_timer = mp.add_timeout(0.5, function()
                pending_seek_timer = nil
                if pending_url ~= final_url or mp.get_property("path") ~= final_url then return end
                pending_url = nil
                mp.commandv("seek", tostring(timestamp_secs), "absolute")
                mp.set_property("pause", "no")
                -- Replace the loading banner with a seek confirmation
                local mins = math.floor(timestamp_secs / 60)
                local secs = timestamp_secs % 60
                show_center(
                    string.format("⏩  Seeked to  %d:%02d", mins, secs),
                    durl,
                    3
                )
            end)
        end
        mp.register_event("file-loaded", pending_seek)

        local mins = math.floor(timestamp_secs / 60)
        local secs = timestamp_secs % 60
        show_center(
            string.format("Loading  —  seek to  %d:%02d", mins, secs),
            durl,
            4
        )
    else
        show_center("Loading…", durl, 3)
    end

    mp.commandv("loadfile", final_url)
end

-- Native, synchronous, and effectively free — no subprocess involved.
-- Returns the first non-empty line of the clipboard, trimmed, or nil.
-- Reading a clipboard that holds non-text (an image, a file drop) yields nil.
local function get_clipboard()
    local text = mp.get_property("clipboard/text")
    if not text or text == "" then return nil end
    local raw = text:match("([^\r\n]+)")
    if raw then raw = raw:match("^%s*(.-)%s*$") end
    if not raw or raw == "" then return nil end
    return raw
end

mp.register_script_message("clipboard-paste", function()
    local raw = get_clipboard()
    if not raw then
        show_center("✗  Clipboard is Empty", nil, 3)
        return
    end
    play_url(raw)
end)
