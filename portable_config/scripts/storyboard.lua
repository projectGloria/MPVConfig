-- storyboard.lua
-- Seekbar thumbnails for YouTube (and any yt-dlp site that has storyboards)
-- without decoding the stream.
--
-- WHY THIS EXISTS
-- thumbfast decodes frames with a hidden mpv. For streams that would mean
-- re-downloading video through yt-dlp, so thumbfast.conf keeps network=no and
-- streams got no thumbnails at all. YouTube already serves "storyboards":
-- small JPEG sprite sheets (sb0 = 320x180 tiles, 3x3 per sheet, one tile every
-- few seconds) that its own player uses for the same purpose.
--
-- HOW
-- * The storyboard formats are already in the yt-dlp JSON that mpv's ytdl_hook
--   fetched to play the video (user-data/mpv/ytdl/json-subprocess-result), so
--   no extra yt-dlp run is needed.
-- * When the seekbar is hovered, the sheet for that time is converted once to
--   raw BGRA by a short `mpv --o=` run (~0.5 s, ~50 KB download), cached in
--   %TEMP%, and the tile is shown with overlay-add using a byte offset and
--   stride into the sheet - so every other tile on that sheet is instant.
--   Neighbouring sheets are prefetched while you scrub.
-- * It speaks the same protocol as thumbfast (`thumb t x y`, `clear`, and a
--   `storyboard-info` broadcast shaped like `thumbfast-info`). Tethys picks
--   storyboard when it is available and falls back to thumbfast otherwise.
--
-- LIVE STREAMS
-- They have no storyboards yet. Instead, at random moments while a live stream
-- plays, the current video frame (screenshot-raw "video": no subtitles/OSD) is
-- shrunk to thumbnail size in memory with LuaJIT FFI and remembered with its
-- time. Hovering shows the nearest remembered frame if one is close enough.
-- Nothing touches disk; frames are dropped on file change.
--
-- Cache files are deleted on file change and on quit (mpv copies overlay
-- pixels on overlay-add, so deleting a shown sheet is safe).
-- Options: portable_config/script-opts/storyboard.conf

local mp      = require "mp"
local utils   = require "mp.utils"
local options = require "mp.options"

local opts = {
    enabled = true,
    max_width = 256,      -- on-screen size (fit, keeps aspect)
    max_height = 256,
    overlay_id = 43,      -- thumbfast uses 42
    max_sheets = 48,      -- converted sheets kept in %TEMP% (~2 MB each for sb0)
    prefetch = 1,         -- sheets on each side of the hovered one to prepare
    mpv_path = "mpv",
    live = true,             -- capture frames of live streams
    live_min_interval = 20,  -- random gap between captures (seconds)
    live_max_interval = 60,
    live_tolerance = 60,     -- show a frame only this close to the hovered time
    live_max_frames = 120,   -- ~150 KB each
}
options.read_options(opts, "storyboard")

local metadata = dofile(mp.command_native({"expand-path", "~~/script-modules/ytdl_metadata.lua"}))

local tmp_dir = os.getenv("TEMP") or os.getenv("TMP") or "."
local pid = tostring(mp.get_property_number("pid", 0) or 0)

local gen = 0           -- bumped on every file change; stale jobs check it
local sb = nil          -- current storyboard description
local sheets = {}       -- k -> {state="loading"|"ready"|"failed", path, used}
local queue = {}        -- sheet indices waiting for conversion
local busy = nil        -- async command id (or true) of the running conversion
local busy_k = nil
local want = nil        -- {t, x, y} of the latest hover
local shown = nil       -- "k:tile:x:y" of what is on screen
local failures = 0
local use_clock = 0

local ffi_ok, ffi = pcall(require, "ffi")
math.randomseed(os.time())
local live = nil        -- {frames = {{t, buf}}, dw, dh, timer, shown_buf}

local function publish()
    local src = sb or (live and #live.frames > 0 and live)
    local ok = src and opts.enabled and true or false
    local data = {
        available = true,
        disabled = not ok,
        width = ok and src.dw or 0,
        height = ok and src.dh or 0,
        overlay_id = opts.overlay_id,
    }
    mp.command_native_async({"script-message", "storyboard-info", utils.format_json(data)}, function() end)
end

local function remove_overlay()
    if shown then
        shown = nil
        mp.command_native_async({"overlay-remove", opts.overlay_id}, function() end)
    end
    if live then live.shown_buf = nil end
end

local function drop_cache()
    if busy and busy ~= true then mp.abort_async_command(busy) end
    busy, busy_k = nil, nil
    for _, s in pairs(sheets) do
        if s.path then os.remove(s.path) end
    end
    sheets, queue = {}, {}
end

local function stop_live()
    if live and live.timer then live.timer:kill() end
    live = nil
end

local function reset()
    gen = gen + 1
    remove_overlay()
    drop_cache()
    stop_live()
    sb, want, failures = nil, nil, 0
end

-- Box-filter a BGRA/BGR0 frame down to dw x dh (3x3 samples per pixel).
local function shrink(r, dw, dh)
    local src = ffi.cast("const uint8_t*", r.data)
    local buf = ffi.new("uint8_t[?]", dw * dh * 4)
    local sx, sy, stride = r.w / dw, r.h / dh, r.stride
    local floor = math.floor
    for y = 0, dh - 1 do
        local r0 = floor((y + 1 / 6) * sy) * stride
        local r1 = floor((y + 3 / 6) * sy) * stride
        local r2 = floor((y + 5 / 6) * sy) * stride
        for x = 0, dw - 1 do
            local b, g, rr = 0, 0, 0
            for i = 0, 2 do
                local col = floor((x + (2 * i + 1) / 6) * sx) * 4
                local q0, q1, q2 = r0 + col, r1 + col, r2 + col
                b = b + src[q0] + src[q1] + src[q2]
                g = g + src[q0 + 1] + src[q1 + 1] + src[q2 + 1]
                rr = rr + src[q0 + 2] + src[q1 + 2] + src[q2 + 2]
            end
            local o = (y * dw + x) * 4
            buf[o], buf[o + 1], buf[o + 2], buf[o + 3] = floor(b / 9), floor(g / 9), floor(rr / 9), 255
        end
    end
    return buf
end

local schedule_capture

local function capture()
    if not live then return end
    local my_gen = gen
    local t = mp.get_property_number("time-pos")
    if mp.get_property_bool("core-idle", true) or not t
        or not mp.get_property_native("video-out-params") then return schedule_capture() end
    mp.command_native_async({"screenshot-raw", "video", "bgra"}, function(success, r)
        if my_gen ~= gen or not live then return end
        if success and type(r) == "table" and type(r.data) == "string"
            and (r.w or 0) > 0 and (r.h or 0) > 0 and #r.data >= (r.stride or 0) * r.h
            and (r.stride or 0) >= r.w * 4 then
            if not live.dw then
                local scale = math.min(opts.max_width / r.w, opts.max_height / r.h)
                live.dw = math.max(1, math.floor(r.w * scale + 0.5))
                live.dh = math.max(1, math.floor(r.h * scale + 0.5))
            end
            local first = #live.frames == 0
            live.frames[#live.frames + 1] = {t = t, buf = shrink(r, live.dw, live.dh)}
            if #live.frames > opts.live_max_frames then table.remove(live.frames, 1) end
            if first then publish() end
        end
        schedule_capture()
    end)
end

schedule_capture = function()
    if not live then return end
    local lo = math.max(1, opts.live_min_interval)
    local hi = math.max(lo, opts.live_max_interval)
    live.timer = mp.add_timeout(lo + math.random() * (hi - lo), capture)
end

local function start_live()
    live = {frames = {}}
    -- First frame soon after the picture starts, then at random gaps.
    live.timer = mp.add_timeout(3, capture)
end

local function draw_live()
    local best, bd
    for _, f in ipairs(live.frames) do
        local d = math.abs(f.t - want.t)
        if not bd or d < bd then best, bd = f, d end
    end
    if not best or bd > opts.live_tolerance then return remove_overlay() end
    local key = "live:" .. best.t .. ":" .. want.x .. ":" .. want.y
    if key == shown then return end
    shown = key
    live.shown_buf = best.buf  -- keep the memory alive while it is on screen
    local addr = "&" .. tostring(ffi.cast("uintptr_t", best.buf)):gsub("U?LL$", "")
    mp.command_native_async({"overlay-add", opts.overlay_id, want.x, want.y, addr,
        0, "bgra", live.dw, live.dh, live.dw * 4, live.dw, live.dh}, function() end)
end

-- Pick the largest storyboard format with usable fragment data.
local function parse(json)
    if type(json) ~= "table" or type(json.formats) ~= "table" then return nil end
    local best
    for _, f in ipairs(json.formats) do
        local is_sb = f.format_note == "storyboard" or tostring(f.format_id or ""):match("^sb%d+$")
        local w, h = tonumber(f.width), tonumber(f.height)
        local rows, cols = tonumber(f.rows), tonumber(f.columns)
        if is_sb and w and h and rows and cols and w > 0 and h > 0 and rows > 0 and cols > 0
            and type(f.fragments) == "table" and #f.fragments > 0
            and (not best or w * h > best.width * best.height) then
            best = f
        end
    end
    if not best then return nil end

    local w, h = tonumber(best.width), tonumber(best.height)
    local rows, cols = tonumber(best.rows), tonumber(best.columns)
    local per_sheet = rows * cols
    local fps = tonumber(best.fps)
    local frags, start = {}, 0
    for _, fr in ipairs(best.fragments) do
        local d = tonumber(fr.duration)
        if not d and fps and fps > 0 then d = per_sheet / fps end
        if type(fr.url) ~= "string" or not d or d <= 0 then return nil end
        frags[#frags + 1] = {url = fr.url, start = start, dur = d}
        start = start + d
    end
    -- Seconds per tile. Full sheets are exact; fall back to fps.
    local interval = frags[1].dur / per_sheet
    if #frags == 1 and fps and fps > 0 then interval = 1 / fps end

    local scale = math.min(opts.max_width / w, opts.max_height / h)
    local headers = type(best.http_headers) == "table" and best.http_headers or {}
    return {
        w = w, h = h, rows = rows, cols = cols, per_sheet = per_sheet,
        interval = interval, frags = frags,
        dw = math.floor(w * scale + 0.5), dh = math.floor(h * scale + 0.5),
        user_agent = headers["User-Agent"],
    }
end

local function locate(t)
    local frags = sb.frags
    t = math.max(0, t)
    local k = #frags
    for i, fr in ipairs(frags) do
        if t < fr.start + fr.dur then k = i break end
    end
    local fr = frags[k]
    local last = math.max(1, math.ceil(fr.dur / sb.interval - 1e-6))
    local tile = math.floor((t - fr.start) / sb.interval)
    tile = math.max(0, math.min(tile, last - 1, sb.per_sheet - 1))
    return k, tile
end

local function draw()
    if live and want then return draw_live() end
    if not (sb and want) then return end
    local k, tile = locate(want.t)
    local s = sheets[k]
    if not (s and s.state == "ready") then return end
    use_clock = use_clock + 1
    s.used = use_clock
    local key = k .. ":" .. tile .. ":" .. want.x .. ":" .. want.y
    if key == shown then return end
    shown = key
    local col, row = tile % sb.cols, math.floor(tile / sb.cols)
    local stride = sb.cols * sb.w * 4
    local offset = row * sb.h * stride + col * sb.w * 4
    mp.command_native_async({"overlay-add", opts.overlay_id, want.x, want.y, s.path,
        offset, "bgra", sb.w, sb.h, stride, sb.dw, sb.dh}, function() end)
end

-- Over the limit: drop the ready sheet farthest from where the mouse is
-- (scrubbing stays local), oldest first on ties. Never the hovered one.
local function evict()
    local cur = want and locate(want.t)
    local count, victim, vdist, vused = 0, nil, -1, math.huge
    for k, s in pairs(sheets) do
        if s.state == "ready" then
            count = count + 1
            local dist = cur and math.abs(k - cur) or 0
            if k ~= cur and (dist > vdist or (dist == vdist and s.used < vused)) then
                victim, vdist, vused = k, dist, s.used
            end
        end
    end
    if count > opts.max_sheets and victim then
        os.remove(sheets[victim].path)
        sheets[victim] = nil
    end
end

local pump

local function convert(k)
    local my_gen = gen
    local fr = sb.frags[k]
    local W, H = sb.cols * sb.w, sb.rows * sb.h
    local path = utils.join_path(tmp_dir, ("mpv-storyboard-%s-%d-%d.bgra"):format(pid, my_gen, k))
    sheets[k] = {state = "loading", path = path}
    -- Sheets at the end of a video are smaller; crop+pad keeps a fixed layout.
    local vf = ("lavfi=[crop=w='min(iw,%d)':h='min(ih,%d)':x=0:y=0,pad=w=%d:h=%d:x=0:y=0:color=black,format=bgra]")
        :format(W, H, W, H)
    local args = {opts.mpv_path, "--no-config", "--load-scripts=no", "--msg-level=all=no",
        "--ytdl=no", "--audio=no", "--frames=1", "--vf=" .. vf,
        "--of=rawvideo", "--ovc=rawvideo", "--o=" .. path}
    if sb.user_agent then args[#args + 1] = "--user-agent=" .. sb.user_agent end
    args[#args + 1] = "--"
    args[#args + 1] = fr.url
    busy_k = k
    local id = mp.command_native_async({name = "subprocess", args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true}, function(success, res)
        if my_gen ~= gen then os.remove(path) return end
        busy, busy_k = nil, nil
        local info = utils.file_info(path)
        if success and res and res.status == 0 and info and info.size == W * H * 4 then
            sheets[k].state = "ready"
            use_clock = use_clock + 1
            sheets[k].used = use_clock
            failures = 0
            evict()
            draw()
        else
            os.remove(path)
            sheets[k].state = "failed"
            failures = failures + 1
            mp.msg.warn(("sheet %d failed (%s)"):format(k, res and (res.error_string or res.status) or "?"))
            if failures >= 3 then
                mp.msg.warn("disabling storyboard thumbnails for this file")
                sb = nil
                remove_overlay()
                publish()
                return
            end
        end
        pump()
    end)
    busy = id or true
end

pump = function()
    if busy or not sb then return end
    while #queue > 0 do
        local k = table.remove(queue, 1)
        if not sheets[k] then return convert(k) end
    end
end

local function enqueue(k)
    if sb.frags[k] and not sheets[k] and k ~= busy_k then queue[#queue + 1] = k end
end

mp.register_script_message("thumb", function(t, x, y)
    t, x, y = tonumber(t), tonumber(x), tonumber(y)
    if not ((sb or live) and t and x and y) then return end
    want = {t = t, x = math.floor(x), y = math.floor(y)}
    if live then return draw_live() end
    local k = locate(t)
    -- Hovered sheet first, then neighbours outward; drop older wishes.
    queue = {}
    enqueue(k)
    for d = 1, opts.prefetch do enqueue(k + d) enqueue(k - d) end
    draw()
    pump()
end)

mp.register_script_message("clear", function()
    want = nil
    remove_overlay()
end)

mp.register_event("start-file", function()
    reset()
    publish()
end)

mp.register_event("file-loaded", function()
    if not opts.enabled or not mp.get_property_bool("demuxer-via-network", false) then return end
    local path = mp.get_property("path", "")
    local json = metadata.get(path)
    local ok, parsed = pcall(parse, json)
    if ok and parsed then
        sb = parsed
        mp.msg.verbose(("%d sheets of %dx%d tiles (%dx%d), %.2fs per tile"):format(
            #sb.frags, sb.cols, sb.rows, sb.w, sb.h, sb.interval))
    elseif opts.live and ffi_ok and type(json) == "table"
        and (json.is_live == true or json.live_status == "is_live") then
        mp.msg.verbose("live stream: capturing frames at random moments")
        start_live()
    end
    publish()
end)

mp.register_event("shutdown", function()
    gen = gen + 1
    stop_live()
    drop_cache()
end)
