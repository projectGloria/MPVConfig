-- Full-screen HQ cover preview. Stays until the video is ready. Caches thumbs.
local mp = require "mp"
local utils = require "mp.utils"
local options = {
    enabled = true,
    seconds = 0,
    timeout = 8,
    ffmpeg = "ffmpeg",
}
require("mp.options").read_options(options, "loading_preview")
local metadata = dofile(mp.command_native({"expand-path", "~~/script-modules/ytdl_metadata.lua"}))

local overlay_id = 42
local job, deadline, pending
local generation = 0
local image_path, image_w, image_h
local overlay_active = false

local function cache_dir()
    local base = mp.command_native({"expand-path", "~~/cache/loading_preview"})
    local fi = utils.file_info(base)
    if not fi or not fi.is_dir then
        os.execute(string.format('mkdir "%s" 2>nul || mkdir -p "%s" 2>/dev/null', base, base))
    end
    return base
end

-- Each cached frame is ~8 MB of raw BGRA, so without a cap the folder grows forever.
-- Runs once at startup (before any on_load use) and keeps only the newest entries.
local MAX_CACHED_FRAMES = 30
local function prune_cache()
    if not utils.readdir then return end
    local base = mp.command_native({"expand-path", "~~/cache/loading_preview"})
    local names = utils.readdir(base, "files")
    if not names or #names <= MAX_CACHED_FRAMES then return end
    local entries = {}
    for _, name in ipairs(names) do
        local path = utils.join_path(base, name)
        local fi = utils.file_info(path)
        entries[#entries + 1] = { path = path, mtime = fi and fi.mtime or 0 }
    end
    table.sort(entries, function(a, b) return a.mtime > b.mtime end)
    for i = MAX_CACHED_FRAMES + 1, #entries do os.remove(entries[i].path) end
end
prune_cache()

local function cache_key(source, id)
    if id and #id == 11 then return "yt-" .. id end
    local s = source:gsub("[^%w%-_%.]", "_")
    if #s > 80 then s = s:sub(1, 80) end
    return s
end

local function cached_path(key, w, h)
    return utils.join_path(cache_dir(), string.format("%s_%dx%d.bgra", key, w, h))
end

local function remove_overlay()
    if overlay_active then
        mp.commandv("overlay-remove", overlay_id)
        overlay_active = false
    end
end

local function release_job()
    if deadline then deadline:kill(); deadline = nil end
    if job then mp.abort_async_command(job); job = nil end
end

local function cont_hook()
    if pending then
        local hook = pending
        pending = nil
        hook:cont()
    end
end

local function cleanup()
    generation = generation + 1
    release_job()
    remove_overlay()
    cont_hook()
    image_path, image_w, image_h = nil, nil, nil
end

local function show_overlay()
    if not image_path or not image_w or not image_h then return end
    local ow, oh = mp.get_osd_size()
    ow = math.max(1, ow or image_w)
    oh = math.max(1, oh or image_h)
    mp.commandv(
        "overlay-add", overlay_id, 0, 0,
        image_path, 0, "bgra", image_w, image_h, image_w * 4,
        ow, oh
    )
    overlay_active = true
end

mp.observe_property("osd-dimensions", "native", function()
    if overlay_active then show_overlay() end
end)
mp.observe_property("fullscreen", "bool", function()
    if overlay_active then
        mp.add_timeout(0.05, function()
            if overlay_active then show_overlay() end
        end)
    end
end)

local function youtube_thumb_url(id)
    return {
        "https://i.ytimg.com/vi/" .. id .. "/maxresdefault.jpg",
        "https://i.ytimg.com/vi/" .. id .. "/hq720.jpg",
        "https://i.ytimg.com/vi/" .. id .. "/sddefault.jpg",
        "https://i.ytimg.com/vi/" .. id .. "/hqdefault.jpg",
    }
end

local function run_ffmpeg(source, output, w, h, current, on_done)
    job = mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stderr = true,
        args = {
            options.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", source,
            "-frames:v", "1", "-an",
            "-vf", string.format(
                "scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d",
                w, h, w, h
            ),
            "-pix_fmt", "bgra", "-f", "rawvideo", output,
        },
    }, function(success, result)
        if current ~= generation then return end
        job = nil
        local info = utils.file_info(output)
        local ok = success and result and result.status == 0
            and info and info.size == w * h * 4
        on_done(ok)
    end)
end

mp.add_hook("on_load", 5, function(hook)
    cleanup()
    if not options.enabled then return end

    local source = mp.get_property("path", "")
    local id = metadata.video_id(source)
    local candidates = {}

    if id and #id == 11 then
        candidates = youtube_thumb_url(id)
    elseif source:match("^%a[%w+.-]*://") then
        return
    else
        candidates = { source }
    end

    hook:defer()
    pending = hook
    local current = generation

    local width, height = mp.get_osd_size()
    if not width or width < 16 then width = 1920 end
    if not height or height < 16 then height = 1080 end
    local w = math.max(1920, math.max(2, math.floor(width / 2) * 2))
    local h = math.max(1080, math.max(2, math.floor(height / 2) * 2))
    w = math.floor(w / 2) * 2
    h = math.floor(h / 2) * 2

    local key = cache_key(source, id)
    local output = cached_path(key, w, h)

    local info = utils.file_info(output)
    if info and info.is_file and info.size == w * h * 4 then
        image_path, image_w, image_h = output, w, h
        show_overlay()
        cont_hook()
        return
    end

    deadline = mp.add_timeout(math.max(0.1, options.timeout), function()
        generation = generation + 1
        release_job()
        remove_overlay()
        cont_hook()
    end)

    local index = 1
    local function try_next()
        if current ~= generation then return end
        if index > #candidates then
            release_job()
            remove_overlay()
            cont_hook()
            return
        end
        local src = candidates[index]
        index = index + 1
        run_ffmpeg(src, output, w, h, current, function(ok)
            if current ~= generation then return end
            if not ok then
                try_next()
                return
            end
            if deadline then deadline:kill(); deadline = nil end
            image_path, image_w, image_h = output, w, h
            show_overlay()
            cont_hook()
        end)
    end

    try_next()
end)

mp.register_event("file-loaded", remove_overlay)
mp.register_event("playback-restart", remove_overlay)
mp.register_event("end-file", cleanup)
mp.register_event("shutdown", cleanup)
