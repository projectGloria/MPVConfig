-- history_menu.lua
-- Persistent watch history with an in-player OSD menu.
-- Placement: ~~/scripts/history_menu.lua

local mp    = require "mp"
local utils = require "mp.utils"
local opt   = require "mp.options"
local metadata = dofile(mp.command_native({"expand-path", "~~/script-modules/ytdl_metadata.lua"}))

local config_dir   = mp.command_native({"expand-path", "~~/"})
config_dir         = config_dir:gsub("[/\\]+$", "")
local history_file = config_dir .. "/mpv-history.txt"
local thumb_dir    = config_dir .. "/cache/history_thumbnails"

-- Prefer the official standalone yt-dlp in portable_config over PATH.
-- Update it with: .\portable_config\yt-dlp.exe -U
local ytdlp = (function()
    local local_copy = mp.command_native({"expand-path", "~~/yt-dlp.exe"})
    local fi = utils.file_info(local_copy)
    if fi and fi.is_file then return local_copy end
    return "yt-dlp"
end)()

-- ── script-opts/history_menu.conf ─────────────────────────────────────────────
local options = {
    max_entries = 300,
    -- Design resolution for UI scale (cards/fonts shrink on smaller windows).
    design_width = 1280,
    design_height = 720,
    -- Clamp scale so cards never become unreadably tiny or huge.
    min_scale = 0.55,
    max_scale = 1.25,
    -- Max simultaneous ffmpeg thumbnail jobs.
    max_thumb_jobs = 2,
}
opt.read_options(options, "history_menu")
local max_entries = options.max_entries

local menu_open          = false
local channel_mode       = false  -- true: grid shows a channel's uploads, not watch history
local history            = {}
local selected           = 1
local record_timer       = nil
local status_msg         = ""
local status_timer       = nil
local temp_overlay_timer = nil
local thumb_cache        = {}   -- path -> true/false, cleared on page change
local last_rendered_page = ""  -- render key: page + grid geometry, see draw_menu
local thumb_dir_created  = false -- lazy mkdir

local overlay   = mp.create_osd_overlay("ass-events")
overlay.z       = 1000

-- Base (design) sizes — cards/fonts scale at draw time; thumb bitmaps stay fixed.
local BASE_THUMB_W = 300
local BASE_THUMB_H = 168
local BASE_CARD_W  = 320
local BASE_CARD_H  = 244
local BASE_GRID_PAD = 24
local BASE_OVERLAY_ID = 50

-- Runtime scaled card geometry (updated every draw_menu / get_grid_dimensions).
local CARD_W, CARD_H = BASE_CARD_W, BASE_CARD_H
local GRID_PAD       = BASE_GRID_PAD
local UI_SCALE       = 1.0

local function ui_scale()
    local ww, wh = mp.get_osd_size()
    if not ww or not wh or ww < 64 or wh < 64 then return 1.0 end
    local sx = ww / (tonumber(options.design_width) or 1280)
    local sy = wh / (tonumber(options.design_height) or 720)
    local s = math.min(sx, sy)
    local mn = tonumber(options.min_scale) or 0.55
    local mx = tonumber(options.max_scale) or 1.25
    if s < mn then s = mn end
    if s > mx then s = mx end
    return s
end

local function apply_scale()
    UI_SCALE = ui_scale()
    local function S(v) return math.max(1, math.floor(v * UI_SCALE + 0.5)) end
    CARD_W   = S(BASE_CARD_W)
    CARD_H   = S(BASE_CARD_H)
    GRID_PAD = S(BASE_GRID_PAD)
end

local function fs(base)
    return math.max(10, math.floor(base * UI_SCALE + 0.5))
end

local draw_menu = function() end

-- 1. Margin Tracking Observer (declared after menu_open and draw_menu so it sees the real state)
local margin_b = 0
mp.observe_property("user-data/osc/margins", "native", function(name, val)
    margin_b = (val and val.b) and val.b or 0
    if menu_open then draw_menu() end
end)

-- ── Thumbnail cache directory is created lazily on first write ───────────────
-- Runs once per session, only when a thumbnail is actually about to be written.
-- Uses mpv's subprocess rather than os.execute: os.execute pops a visible
-- console window on Windows, mpv spawns with CREATE_NO_WINDOW.
local function ensure_thumb_dir()
    if thumb_dir_created then return end
    thumb_dir_created = true
    local td = thumb_dir:gsub("/", "\\")
    mp.command_native({
        name          = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = { "cmd", "/c", "if not exist \"" .. td .. "\" mkdir \"" .. td .. "\"" },
    })
end

-- ── Path-based thumbnail filename hash ───────────────────────────────────────
-- Using the path (not title) as the hash source avoids collisions between two
-- different local files that share the same title prefix.
-- Thumbs are stored at the *base* resolution so the cache stays stable across
-- window resizes. Display uses that fixed bitmap; cards/fonts scale around it.
local function thumb_file(id)
    if not id or id == "" then return nil end
    return thumb_dir .. "/" .. id .. ".bgra"
end

local function thumb_bytes()
    return BASE_THUMB_W * BASE_THUMB_H * 4
end

-- Records written before the portable-path change stored a full absolute
-- path. Reduce anything to its bare id so old entries keep working.
local function thumb_to_id(value)
    if not value or value == "" then return nil end
    local name = tostring(value):gsub("\\", "/"):match("([^/]+)$") or tostring(value)
    name = name:gsub("%.bgra$", "")
    if name == "" then return nil end
    return name
end

local function thumb_id(path)
    local h = 5381
    for i = 1, #path do
        h = ((h * 33) + string.byte(path, i)) % 0x7fffffff
    end
    return string.format("%08x", h)
end

local function get_grid_dimensions()
    apply_scale()
    local ww, wh = mp.get_osd_size()
    if not ww or not wh or ww < 64 then ww, wh = 1280, 720 end
    local margin_x = math.max(40, math.floor(60 * UI_SCALE))
    local margin_top = math.max(80, math.floor(115 * UI_SCALE))
    local margin_bot = math.max(40, math.floor(60 * UI_SCALE))
    local cols = math.max(1, math.floor((ww - margin_x * 2) / (CARD_W + GRID_PAD)))
    local rows = math.max(1, math.floor((wh - margin_top - margin_bot) / (CARD_H + GRID_PAD)))
    return cols, rows, cols * rows, ww, wh, margin_x, margin_top
end

local function clean_text(s)
    if not s then return "" end
    s = tostring(s)
    s = s:gsub("[\r\n\t]", " ")
    s = s:gsub("%s+", " ")
    return s
end

local function ass_escape(s)
    s = clean_text(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("{",  "\\{")
    s = s:gsub("}",  "\\}")
    return s
end

local function basename(path)
    if not path then return "Unknown" end
    local name = path:gsub("\\", "/"):match("([^/]+)$")
    return name or path
end

local function strip_ytdl_prefix(url)
    if not url then return "" end
    return url:gsub("^ytdl://", "")
end

local function normalize_url(url)
    if not url then return "" end
    url = strip_ytdl_prefix(url)

    if not url:match("^https?://") then
        return url:gsub("\\", "/"):lower()
    end

    local strip_list = { "si", "pp", "fbclid", "t", "start" }
    for _, param in ipairs(strip_list) do
        url = url:gsub("%?" .. param .. "=[^&]*&", "?")
        url = url:gsub("%?" .. param .. "=[^&]*$", "")
        url = url:gsub("&" .. param .. "=[^&]*",   "")
    end
    url = url:gsub("%?utm_[^=]+=[^&]*&", "?")
    url = url:gsub("%?utm_[^=]+=[^&]*$", "")
    url = url:gsub("&utm_[^=]+=[^&]*",   "")
    return url
end

local function source_from_url(path)
    path = strip_ytdl_prefix(path or "")
    local host = path:match("^https?://([^/%?]+)")
    if host then
        host = host:gsub("^www%.", "")
        return host
    end
    if path:match("^%a:[/\\]") or path:match("^/") then
        return "Local file"
    end
    return ""
end

local function source_from_ytdlp_json(json)
    if type(json) ~= "table" then return "" end
    local keys = { "channel", "uploader", "creator", "artist", "uploader_id", "channel_id" }
    for _, key in ipairs(keys) do
        local value = json[key]
        if value and tostring(value) ~= "" then return clean_text(value) end
    end
    return ""
end

local function title_from_ytdlp_json(json)
    if type(json) ~= "table" then return "" end
    local value = json["title"]
    if value and tostring(value) ~= "" then return clean_text(value) end
    return ""
end

local function get_source_name(path)
    local ytdl_json = mp.get_property_native("user-data/mpv/ytdl/json", nil)
    if type(ytdl_json) == "table" then
        local source = source_from_ytdlp_json(ytdl_json)
        if source ~= "" then return source end
    end
    local meta = mp.get_property_native("metadata", {})
    if type(meta) == "table" then
        local keys = { "channel", "uploader", "artist", "author", "creator", "album_artist" }
        for _, key in ipairs(keys) do
            local value = meta[key]
            if value and tostring(value) ~= "" then return clean_text(value) end
        end
    end
    return source_from_url(path)
end

local function clear_thumbnails()
    for i = 0, 40 do
        mp.command_native({"overlay-remove", BASE_OVERLAY_ID + i})
    end
end

local function clear_overlay()
    if temp_overlay_timer then temp_overlay_timer:kill(); temp_overlay_timer = nil end
    overlay.data = ""
    overlay:update()
    clear_thumbnails()
end

local function show_overlay(lines, seconds)
    if temp_overlay_timer then temp_overlay_timer:kill(); temp_overlay_timer = nil end
    apply_scale()
    local ww, wh = mp.get_osd_size()
    if not ww or not wh or ww < 64 then ww, wh = 1280, 720 end
    overlay.res_x = ww
    overlay.res_y = wh
    local ass = {}
    local pos_x = math.max(20, math.floor(40 * UI_SCALE))
    local pos_y = math.max(20, math.floor(40 * UI_SCALE))
    table.insert(ass, string.format("{\\an7\\pos(%d,%d)\\fnMontserrat ExtraBold\\q2\\fs%d\\bord2\\shad1\\1c&HFFFFFF&\\3c&H000000&}",
        pos_x, pos_y, fs(24)))
    for _, line in ipairs(lines) do table.insert(ass, ass_escape(line)) end
    overlay.data = table.concat(ass, "\\N")
    overlay:update()
    if seconds and seconds > 0 then
        temp_overlay_timer = mp.add_timeout(seconds, clear_overlay)
    end
end

local function read_history()
    local list = {}
    local f = io.open(history_file, "r")
    if not f then return list end
    for line in f:lines() do
        local item = utils.parse_json(line)
        if type(item) == "table" and item.path and item.title then
            if not item.source or item.source == "" then
                item.source = source_from_url(item.path)
            end
            if not item.count then item.count = 1 end
            item.thumb = thumb_to_id(item.thumb)
            table.insert(list, item)
        end
    end
    f:close()
    return list
end

local function write_history(list)
    local f = io.open(history_file, "w")
    if not f then
        show_overlay({ "History error:", "Cannot write file:", history_file }, 5)
        return
    end
    for _, item in ipairs(list) do
        f:write(utils.format_json(item), "\n")
    end
    f:close()
end

local function add_to_history(path, title, source, thumb, is_update)
    if not path or path == "" then return end

    path = normalize_url(path)
    title = clean_text(title)
    if title == "" then title = clean_text(basename(path)) end
    source = clean_text(source)
    if source == "" then source = source_from_url(path) end

    local old_list  = read_history()
    local new_list  = {}
    local norm_path = path  -- already normalized above

    local existing_count = 0
    local existing_thumb = nil
    local existing_time  = os.time()
    for _, item in ipairs(old_list) do
        if normalize_url(item.path) == norm_path then
            existing_count = item.count or 1
            existing_thumb = item.thumb
            existing_time  = item.time or os.time()
            break
        end
    end
    local new_count = is_update and (existing_count > 0 and existing_count or 1) or (existing_count + 1)
    local final_thumb = thumb or existing_thumb

    table.insert(new_list, {
        title  = title,
        source = source,
        path   = path,
        time   = is_update and existing_time or os.time(),
        count  = new_count,
        thumb  = final_thumb,
    })

    for _, item in ipairs(old_list) do
        if normalize_url(item.path) ~= norm_path then
            table.insert(new_list, item)
        end
        if #new_list >= max_entries then break end
    end

    write_history(new_list)
end

local thumbnail_jobs = {}
local thumbnail_job_count = 0
local thumbnail_queue = {}
local max_thumb_jobs = math.max(1, tonumber(options.max_thumb_jobs) or 2)

local function valid_thumbnail(path)
    local info = utils.file_info(path)
    return info and info.is_file and info.size == thumb_bytes()
end

local function pump_thumb_queue()
    while thumbnail_job_count < max_thumb_jobs and #thumbnail_queue > 0 do
        local job = table.remove(thumbnail_queue, 1)
        if job and not thumbnail_jobs[job.id] then
            thumbnail_jobs[job.id] = true
            thumbnail_job_count = thumbnail_job_count + 1
            mp.command_native_async({
                name = "subprocess", playback_only = false,
                args = job.args,
            }, function(success, result)
                thumbnail_jobs[job.id] = nil
                thumbnail_job_count = math.max(0, thumbnail_job_count - 1)
                if job.on_done then job.on_done(success, result) end
                pump_thumb_queue()
            end)
        end
    end
end

local function enqueue_thumb(id, args, on_done)
    if thumbnail_jobs[id] then return end
    for _, j in ipairs(thumbnail_queue) do
        if j.id == id then return end
    end
    table.insert(thumbnail_queue, { id = id, args = args, on_done = on_done })
    pump_thumb_queue()
end

local function record_current()
    local path = strip_ytdl_prefix(mp.get_property("path", ""))
    if path == "" then return end

    local fallback_title = mp.get_property("media-title", "")
    if fallback_title == "" then fallback_title = mp.get_property("filename", "") end
    local fallback_source = get_source_name(path)

    if not path:match("^https?://") then
        if not path:match("^%a[%w+.-]*://") and
            not path:match("^%a:[/\\]") and not path:match("^[/\\]") then
            path = utils.join_path(mp.get_property("working-directory", ""), path)
        end
        local source = utils.file_info(path)
        -- Include source identity in the cache key so changed files regenerate.
        local fingerprint = source and source.is_file and source.mtime and source.size and
            (tostring(source.size) .. ":" .. tostring(source.mtime))
        local id = thumb_id(path .. (fingerprint and (":" .. fingerprint) or ""))
        local thumb_path = thumb_file(id)
        local cached = fingerprint and valid_thumbnail(thumb_path)
        add_to_history(path, fallback_title, fallback_source, cached and id or nil)
        if cached or thumbnail_jobs[id] then return end
        ensure_thumb_dir()
        enqueue_thumb(id, {
            "ffmpeg", "-y", "-loglevel", "error", "-ss", "00:00:10", "-i", path,
            "-frames:v", "1", "-vf", string.format("scale=%d:%d", BASE_THUMB_W, BASE_THUMB_H),
            "-pix_fmt", "bgra", "-f", "rawvideo", thumb_path
        }, function(success, result)
            if success and result and result.status == 0 and valid_thumbnail(thumb_path) then
                add_to_history(path, fallback_title, fallback_source, id, true)
            end
        end)
        return
    end

    add_to_history(path, fallback_title, fallback_source)
    local function update_metadata(json)
        local title, source, thumb_url = fallback_title, fallback_source, nil
        if type(json) == "table" then
            local yt, ys = title_from_ytdlp_json(json), source_from_ytdlp_json(json)
            if yt ~= "" then title = yt end
            if ys ~= "" then source = ys end
            thumb_url = json.thumbnail
        end
        if type(thumb_url) ~= "string" or thumb_url == "" then
            add_to_history(path, title, source, nil, true)
            return
        end
        local id = thumb_id(path)
        local thumb_path = thumb_file(id)
        if valid_thumbnail(thumb_path) then
            add_to_history(path, title, source, id, true)
            return
        end
        if thumbnail_jobs[id] then return end
        ensure_thumb_dir()
        enqueue_thumb(id, {
            "ffmpeg", "-y", "-loglevel", "error", "-i", thumb_url, "-frames:v", "1",
            "-vf", string.format("scale=%d:%d", BASE_THUMB_W, BASE_THUMB_H),
            "-pix_fmt", "bgra", "-f", "rawvideo", thumb_path
        }, function(success, result)
            local valid = success and result and result.status == 0 and valid_thumbnail(thumb_path)
            add_to_history(path, title, source, valid and id or nil, true)
        end)
    end

    local json = metadata.get(path)
    if json then update_metadata(json); return end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = false,
        args = {ytdlp, "--skip-download", "--dump-single-json", "--no-warnings", "--no-playlist", path}
    }, function(success, result)
        local data = success and result and result.status == 0 and
            utils.parse_json(result.stdout or "") or nil
        update_metadata(data)
    end)
end

local function schedule_record()
    if record_timer then record_timer:kill(); record_timer = nil end
    record_timer = mp.add_timeout(2.0, record_current)
end

local function close_menu()
    if not menu_open then return end
    menu_open = false
    local binds = {
        "history_up", "history_down", "history_left", "history_right",
        "history_enter", "history_kp_enter", "history_esc", "history_bs",
        "history_delete", "history_wheel_up", "history_wheel_down",
        "history_page_up", "history_page_down", "history_home", "history_end"
    }
    for _, b in ipairs(binds) do mp.remove_key_binding(b) end
    clear_overlay()
    mp.commandv("script-message", "osc-idlescreen", "yes", "true")
end

-- Invalidate thumb cache when history changes (new page, menu reopen, delete)
local function invalidate_thumb_cache()
    thumb_cache = {}
    last_rendered_page = ""
end

draw_menu = function()
    if not menu_open then return end

    if #history == 0 then
        show_overlay({ "Played History", "", "History is empty." }, 5)
        return
    end

    local grid_cols, grid_rows, visible_items, ww, wh, margin_x, margin_top = get_grid_dimensions()

    if selected < 1 then selected = 1 end
    if selected > #history then selected = #history end

    local total_pages = math.max(1, math.ceil(#history / visible_items))
    local page = math.floor((selected - 1) / visible_items)
    local first = page * visible_items + 1
    local last  = math.min(#history, first + visible_items - 1)

    local ass = {}
    overlay.res_x = ww
    overlay.res_y = wh

    -- Solid darkened background
    table.insert(ass, string.format("{\\an7\\pos(0,0)\\bord0\\1c&H080808&\\alpha&H00&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}", ww, ww, wh, wh))

    -- Top bar header (scaled fonts)
    local header_x = margin_x
    local header_y = math.max(20, math.floor(40 * UI_SCALE))
    local title_text = channel_mode and ("Channel: " .. ass_escape(history[1].source or "")) or "Watch History"
    local hint_text  = channel_mode and "Arrows/Scroll, Enter" or "Arrows/Scroll, Enter, Del"
    table.insert(ass, string.format(
        "{\\an7\\pos(%d,%d)\\fnMontserrat ExtraBold\\q2\\fs%d\\b1\\1c&HFFFFFF&\\bord0\\shad0}%s" ..
        "{\\b0\\fs%d\\1c&HAAAAAA&}   [Item %d of %d  •  Page %d/%d]  —  %s",
        header_x, header_y, fs(28), title_text, fs(18),
        selected, #history, page + 1, total_pages, hint_text
    ))

    if status_msg ~= "" then
        table.insert(ass, string.format("{\\an7\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\1c&H30E0FF&\\bord0}%s",
            header_x, header_y + fs(28) + 8, fs(18), ass_escape(status_msg)))
    end

    -- Only re-blit thumbnails when page/geometry changes (avoids re-reading BGRA every key).
    local render_key = string.format("%d:%d:%d:%d:%d:%.2f", page, grid_cols, grid_rows, ww, wh, UI_SCALE)
    local page_changed = (render_key ~= last_rendered_page)
    if page_changed then
        clear_thumbnails()
        last_rendered_page = render_key
    end

    local start_x = margin_x
    local start_y = margin_top

    -- Display thumb size: prefer base bitmap; if card is too small, shrink the
    -- ASS frame and skip the pixel overlay (bitmap is fixed 300×168).
    local disp_tw = BASE_THUMB_W
    local disp_th = BASE_THUMB_H
    local thumb_pad = math.max(6, math.floor(10 * UI_SCALE))
    local can_blit_thumb = (CARD_W >= disp_tw + thumb_pad * 2) and (CARD_H >= disp_th + math.floor(50 * UI_SCALE))
    if not can_blit_thumb then
        -- Fit a proportionally smaller frame inside the scaled card for the placeholder.
        disp_tw = math.max(40, CARD_W - thumb_pad * 2)
        disp_th = math.max(24, math.floor(disp_tw * BASE_THUMB_H / BASE_THUMB_W))
    end

    local max_src_chars = math.max(10, math.floor(26 * UI_SCALE))
    local max_title_chars = math.max(12, math.floor(40 * UI_SCALE))

    for i = first, last do
        local idx = i - first
        local col = idx % grid_cols
        local row = math.floor(idx / grid_cols)

        local x = start_x + col * (CARD_W + GRID_PAD)
        local y = start_y + row * (CARD_H + GRID_PAD)

        local item = history[i]
        local is_selected = (i == selected)

        -- Selection glow & card container
        if is_selected then
            table.insert(ass, string.format("{\\an7\\pos(%d,%d)\\bord0\\1c&H30E0FF&\\alpha&H30&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
                x - 4, y - 4, CARD_W + 8, CARD_W + 8, CARD_H + 8, CARD_H + 8))
            table.insert(ass, string.format("{\\an7\\pos(%d,%d)\\bord0\\1c&H1A1A1A&\\alpha&H00&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
                x, y, CARD_W, CARD_W, CARD_H, CARD_H))
        else
            table.insert(ass, string.format("{\\an7\\pos(%d,%d)\\bord0\\1c&H141414&\\alpha&H00&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
                x, y, CARD_W, CARD_W, CARD_H, CARD_H))
        end

        -- Thumbnail frame background
        local tfx = x + math.floor((CARD_W - disp_tw) / 2)
        local tfy = y + thumb_pad
        table.insert(ass, string.format("{\\an7\\pos(%d,%d)\\bord0\\1c&H050505&\\alpha&H00&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
            tfx, tfy, disp_tw, disp_tw, disp_th, disp_th))

        -- Thumbnail image (only when the card can fit the base bitmap)
        local has_thumb = false
        local thumb_path = thumb_file(item.thumb)
        if can_blit_thumb and thumb_path then
            local cached = thumb_cache[thumb_path]
            if cached == nil then
                local f = io.open(thumb_path, "rb")
                cached = f ~= nil
                if f then f:close() end
                thumb_cache[thumb_path] = cached
            end
            if cached then
                has_thumb = true
                if page_changed then
                    mp.command_native({
                        "overlay-add", BASE_OVERLAY_ID + idx,
                        math.floor(tfx), math.floor(tfy),
                        thumb_path, 0, "bgra", BASE_THUMB_W, BASE_THUMB_H, BASE_THUMB_W * 4
                    })
                end
            end
        end

        if not has_thumb then
            table.insert(ass, string.format("{\\an5\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\1c&H666666&\\bord0}No Preview",
                x + CARD_W / 2, tfy + disp_th / 2, fs(16)))
        end

        local source = item.source or "Unknown"
        local title  = item.title  or basename(item.path)
        if #source > max_src_chars then source = source:sub(1, max_src_chars - 3) .. "..." end
        if #title > max_title_chars then title = title:sub(1, max_title_chars - 3) .. "..." end

        local meta_y1 = tfy + disp_th + math.max(8, math.floor(16 * UI_SCALE))
        local meta_y2 = meta_y1 + math.max(14, math.floor(22 * UI_SCALE))
        local source_color = is_selected and "H30E0FF" or "H55C5D8"
        table.insert(ass, string.format("{\\an7\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\b1\\1c&%s&\\bord0}%s",
            x + math.floor(12 * UI_SCALE), meta_y1, fs(13), source_color, ass_escape(source)))

        if item.count and item.count > 1 then
            table.insert(ass, string.format("{\\an9\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\b1\\1c&HFFAA20&\\bord0}×%d",
                x + CARD_W - math.floor(12 * UI_SCALE), meta_y1, fs(12), item.count))
        end

        local title_color = is_selected and "HFFFFFF" or "HDDDDDD"
        local title_weight = is_selected and "\\b1" or "\\b0"
        table.insert(ass, string.format("{\\an7\\pos(%d,%d)\\fnMontserrat ExtraBold%s\\q2\\fs%d\\1c&%s&\\bord0}%s",
            x + math.floor(12 * UI_SCALE), meta_y2, title_weight, fs(14), title_color, ass_escape(title)))
    end

    overlay.data = table.concat(ass, "\n")
    overlay:update()
end

local function set_status(msg, seconds)
    status_msg = msg or ""
    if status_timer then status_timer:kill(); status_timer = nil end
    if seconds and seconds > 0 then
        status_timer = mp.add_timeout(seconds, function()
            status_msg = ""
            draw_menu()
        end)
    end
    draw_menu()
end

local function move_selection(dx, dy)
    if #history == 0 then return end
    -- get_grid_dimensions() will be called again inside draw_menu;
    -- we call it once here only to know grid_cols for horizontal/vertical math.
    local grid_cols = get_grid_dimensions()
    local new_sel = selected + dx + (dy * grid_cols)
    if new_sel < 1 then new_sel = 1 end
    if new_sel > #history then new_sel = #history end
    selected = new_sel
    draw_menu()
end

local function page_selection(delta)
    if #history == 0 then return end
    local _, _, visible_items = get_grid_dimensions()
    local new_sel = selected + (delta * visible_items)
    if new_sel < 1 then new_sel = 1 end
    if new_sel > #history then new_sel = #history end
    selected = new_sel
    draw_menu()
end

local function play_selected()
    if #history == 0 then close_menu(); return end
    local item = history[selected]
    if not item or not item.path then close_menu(); return end
    local path = item.path
    close_menu()
    mp.commandv("loadfile", path, "replace")
end

local function delete_selected()
    if #history == 0 then return end
    -- Channel items are a transient fetch, not persisted history: nothing to delete.
    if channel_mode then return end
    local item = history[selected]
    local removed = item.title or item.path
    local tf = thumb_file(item.thumb)
    if tf then os.remove(tf) end
    table.remove(history, selected)
    invalidate_thumb_cache()
    if selected > #history then selected = math.max(1, #history) end
    write_history(history)
    set_status("Removed: " .. clean_text(removed):sub(1, 60), 2)
end

local function open_menu(list, as_channel)
    history = list
    channel_mode = as_channel

    menu_open = true
    selected  = 1
    status_msg = ""
    invalidate_thumb_cache()

    mp.commandv("script-message", "osc-idlescreen", "no", "true")

    mp.add_forced_key_binding("UP",         "history_up",         function() move_selection(0, -1) end, { repeatable = true })
    mp.add_forced_key_binding("DOWN",       "history_down",       function() move_selection(0, 1)  end, { repeatable = true })
    mp.add_forced_key_binding("LEFT",       "history_left",       function() move_selection(-1, 0) end, { repeatable = true })
    mp.add_forced_key_binding("RIGHT",      "history_right",      function() move_selection(1, 0)  end, { repeatable = true })
    mp.add_forced_key_binding("WHEEL_UP",   "history_wheel_up",   function() move_selection(0, -1) end)
    mp.add_forced_key_binding("WHEEL_DOWN", "history_wheel_down", function() move_selection(0, 1)  end)
    mp.add_forced_key_binding("PGUP",       "history_page_up",    function() page_selection(-1) end)
    mp.add_forced_key_binding("PGDWN",      "history_page_down",  function() page_selection(1)  end)
    mp.add_forced_key_binding("HOME",       "history_home",       function() selected = 1; draw_menu() end)
    mp.add_forced_key_binding("END",        "history_end",        function() selected = #history; draw_menu() end)
    mp.add_forced_key_binding("ENTER",      "history_enter",      play_selected)
    mp.add_forced_key_binding("KP_ENTER",   "history_kp_enter",   play_selected)
    mp.add_forced_key_binding("DEL",        "history_delete",     delete_selected)
    mp.add_forced_key_binding("ESC",        "history_esc",        close_menu)
    mp.add_forced_key_binding("BS",         "history_bs",         close_menu)

    draw_menu()
end

local function show_history()
    local list = read_history()
    if #list == 0 then
        show_overlay({ "Played History", "", "History is empty." }, 5)
        return
    end
    open_menu(list, false)
end

local function toggle_history()
    if menu_open then close_menu() else show_history() end
end

-- ── Channel uploads (Ctrl+G) ──────────────────────────────────────────────────
-- Everything is prefetched silently after a YouTube video loads: channel
-- resolve -> flat upload list -> thumbnails via the shared ffmpeg queue. The
-- key press only opens an already-populated grid.
local CHANNEL_FETCH_COUNT = 30
local CHANNEL_FETCH_DELAY = 5.0  -- after record_current's 2s, so we don't pile onto stream startup
local SEP = "|||"
local channel_cache  = {}   -- channel_url -> items (session-lifetime)
local channel_items  = nil  -- items for the currently playing video's channel
local channel_gen    = 0
local channel_timer  = nil

local function fetch_channel_items(channel_url, channel_name, gen)
    if channel_cache[channel_url] then
        if gen == channel_gen then channel_items = channel_cache[channel_url] end
        return
    end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = false,
        args = { ytdlp, "--no-warnings", "--flat-playlist", "--playlist-end", tostring(CHANNEL_FETCH_COUNT),
                 "--print", "%(id)s" .. SEP .. "%(title)s", (channel_url:gsub("/+$", "")) .. "/videos" }
    }, function(success, result)
        if not (success and result and result.status == 0) then return end
        local items = {}
        for line in (result.stdout or ""):gmatch("[^\r\n]+") do
            local id, title = line:match("^([%w_-]+)" .. SEP:gsub("%p", "%%%0") .. "(.*)$")
            if id and #id == 11 then
                local url = "https://www.youtube.com/watch?v=" .. id
                local tid = thumb_id(url)
                local tpath = thumb_file(tid)
                local item = {
                    title = clean_text(title), source = channel_name, path = url, count = 1,
                    thumb = valid_thumbnail(tpath) and tid or nil,
                }
                table.insert(items, item)
                if not item.thumb then
                    ensure_thumb_dir()
                    enqueue_thumb(tid, {
                        "ffmpeg", "-y", "-loglevel", "error", "-i",
                        "https://i.ytimg.com/vi/" .. id .. "/mqdefault.jpg", "-frames:v", "1",
                        "-vf", string.format("scale=%d:%d", BASE_THUMB_W, BASE_THUMB_H),
                        "-pix_fmt", "bgra", "-f", "rawvideo", tpath
                    }, function(ok, res)
                        -- Only publish the thumb once ffmpeg finished, never a half-written file.
                        if ok and res and res.status == 0 and valid_thumbnail(tpath) then item.thumb = tid end
                    end)
                end
            end
        end
        if #items == 0 then return end
        channel_cache[channel_url] = items
        if gen == channel_gen then channel_items = items end
    end)
end

local function prefetch_channel()
    channel_gen = channel_gen + 1
    channel_items = nil
    if channel_timer then channel_timer:kill(); channel_timer = nil end
    local url = strip_ytdl_prefix(mp.get_property("path", ""))
    if not metadata.video_id(url) then return end
    local gen = channel_gen
    channel_timer = mp.add_timeout(CHANNEL_FETCH_DELAY, function()
        channel_timer = nil
        if gen ~= channel_gen then return end
        local json = metadata.get(url)
        if json and type(json.channel_url) == "string" and json.channel_url ~= "" then
            fetch_channel_items(json.channel_url, source_from_ytdlp_json(json), gen)
            return
        end
        mp.command_native_async({
            name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = false,
            args = { ytdlp, "--no-warnings", "--no-playlist", "--no-download", "--print",
                     "%(channel_url)s" .. SEP .. "%(channel)s", url }
        }, function(success, result)
            if gen ~= channel_gen or not (success and result and result.status == 0) then return end
            local cu, name = (result.stdout or ""):match("^(https?://[^\r\n]-)" .. SEP:gsub("%p", "%%%0") .. "([^\r\n]*)")
            if cu then fetch_channel_items(cu, clean_text(name), gen) end
        end)
    end)
end

local function toggle_channel_history()
    if menu_open then close_menu(); return end
    if not channel_items or #channel_items == 0 then
        show_overlay({ "Channel Videos", "", "Not available (not a YouTube video, or still loading)." }, 3)
        return
    end
    open_menu(channel_items, true)
end

mp.register_event("file-loaded", function()
    schedule_record()
    prefetch_channel()
end)
mp.register_event("end-file", function()
    if record_timer then record_timer:kill(); record_timer = nil end
    channel_gen = channel_gen + 1
    channel_items = nil
    if channel_timer then channel_timer:kill(); channel_timer = nil end
end)
mp.add_key_binding(nil, "show_history", toggle_history)
mp.add_key_binding(nil, "show_channel_history", toggle_channel_history)

-- Redraw scaled layout when the window is resized while the menu is open.
mp.observe_property("osd-dimensions", "native", function()
    if menu_open then
        last_rendered_page = ""  -- force thumbnail re-blit at new positions
        draw_menu()
    end
end)