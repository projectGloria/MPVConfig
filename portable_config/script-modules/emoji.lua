-- Colour emoji for OSD text.
--
-- libass cannot draw colour glyphs and Windows fonts have no flag emoji, so
-- emoji are drawn as images over the text instead:
--   * M.split() finds emoji sequences (flags, ZWJ, keycaps, skin tones, tag
--     flags) and names them the way Twemoji names its files.
--   * M.layer() downloads each Twemoji PNG once (CC-BY 4.0, jdecked/twemoji),
--     converts it to raw BGRA with a short `mpv --o=` run into ~~cache/twemoji,
--     and composes the emoji of one text line into a single premultiplied BGRA
--     buffer drawn with `overlay-add &<address>`.
-- Until an image is ready (or if it does not exist) the text keeps the
-- original character, so nothing is ever lost.

local M = {}

M.VERSION = "16.0.1"
M.URL = "https://cdn.jsdelivr.net/gh/jdecked/twemoji@%s/assets/72x72/%s.png"
M.SRC = 72 -- source image size

-- UTF-8 -> array of code points (invalid bytes are kept as-is, as U+FFFD-ish
-- markers carrying their byte so the text round-trips).
local function decode(s)
    local cps, raw = {}, {}
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len, cp
        if c < 0x80 then len, cp = 1, c
        elseif c >= 0xF0 and c < 0xF8 then len, cp = 4, c % 0x08
        elseif c >= 0xE0 then len, cp = 3, c % 0x10
        elseif c >= 0xC0 then len, cp = 2, c % 0x20
        else len, cp = 1, nil end
        if cp and i + len - 1 <= n then
            for k = i + 1, i + len - 1 do
                local b = s:byte(k)
                if b < 0x80 or b >= 0xC0 then cp = nil break end
                cp = cp * 64 + b % 64
            end
        else
            cp = nil
        end
        if not cp then len, cp = 1, -1 end
        cps[#cps + 1] = cp
        raw[#raw + 1] = s:sub(i, i + len - 1)
        i = i + len
    end
    return cps, raw
end

-- Characters that are emoji by default (Emoji_Presentation) in the BMP.
local BMP_EMOJI = {}
for _, r in ipairs({
    {0x231A, 0x231B}, {0x23E9, 0x23EC}, {0x23F0, 0x23F0}, {0x23F3, 0x23F3},
    {0x25FD, 0x25FE}, {0x2614, 0x2615}, {0x2648, 0x2653}, {0x267F, 0x267F},
    {0x2693, 0x2693}, {0x26A1, 0x26A1}, {0x26AA, 0x26AB}, {0x26BD, 0x26BE},
    {0x26C4, 0x26C5}, {0x26CE, 0x26CE}, {0x26D4, 0x26D4}, {0x26EA, 0x26EA},
    {0x26F2, 0x26F3}, {0x26F5, 0x26F5}, {0x26FA, 0x26FA}, {0x26FD, 0x26FD},
    {0x2705, 0x2705}, {0x270A, 0x270B}, {0x2728, 0x2728}, {0x274C, 0x274C},
    {0x274E, 0x274E}, {0x2753, 0x2755}, {0x2757, 0x2757}, {0x2795, 0x2797},
    {0x27B0, 0x27B0}, {0x27BF, 0x27BF}, {0x2B1B, 0x2B1C}, {0x2B50, 0x2B50},
    {0x2B55, 0x2B55},
}) do
    for cp = r[1], r[2] do BMP_EMOJI[cp] = true end
end

local function is_ri(cp) return cp >= 0x1F1E6 and cp <= 0x1F1FF end
local function is_skin(cp) return cp >= 0x1F3FB and cp <= 0x1F3FF end
local function is_tag(cp) return cp >= 0xE0020 and cp <= 0xE007F end
local function is_keycap_base(cp)
    return cp == 0x23 or cp == 0x2A or (cp >= 0x30 and cp <= 0x39)
end
-- Symbols that become emoji when followed by U+FE0F.
local function is_symbol(cp)
    return cp == 0xA9 or cp == 0xAE or (cp >= 0x2000 and cp <= 0x2BFF)
        or cp == 0x3030 or cp == 0x303D or cp == 0x3297 or cp == 0x3299
end
local function is_wide_emoji(cp)
    return cp >= 0x1F000 and cp <= 0x1FAFF and not is_skin(cp) or BMP_EMOJI[cp]
end

-- Twemoji file name: lower-case hex joined by "-"; U+FE0F is dropped unless
-- the sequence contains a ZWJ (that is how Twemoji names its files).
function M.name(cps)
    local has_zwj = false
    for _, cp in ipairs(cps) do if cp == 0x200D then has_zwj = true end end
    local parts = {}
    for _, cp in ipairs(cps) do
        if has_zwj or cp ~= 0xFE0F then parts[#parts + 1] = ("%x"):format(cp) end
    end
    return table.concat(parts, "-")
end

-- Same name with every U+FE0F removed (fallback for a few ZWJ files).
function M.alt_name(name)
    local alt = ("-" .. name .. "-"):gsub("%-fe0f%-", "-"):gsub("%-fe0f%-", "-")
    alt = alt:sub(2, -2)
    return alt ~= name and alt or nil
end

-- Splits text into {text=...} and {emoji=<utf8>, name=<twemoji name>} parts.
function M.split(s)
    local out = {}
    if type(s) ~= "string" or s == "" then return out end
    local cps, raw = decode(s)
    local n, i = #cps, 1
    local buf = {}
    local function flush()
        if #buf > 0 then out[#out + 1] = {text = table.concat(buf)} buf = {} end
    end
    while i <= n do
        local cp = cps[i]
        local j -- last index of the emoji sequence starting at i
        if is_ri(cp) then
            if i < n and is_ri(cps[i + 1]) then j = i + 1 end
        elseif is_keycap_base(cp) then
            local k = i + 1
            if cps[k] == 0xFE0F then k = k + 1 end
            if cps[k] == 0x20E3 then j = k end
        elseif cps[i + 1] == 0xFE0E then
            j = nil -- explicit text presentation
        elseif is_wide_emoji(cp) or (is_symbol(cp) and cps[i + 1] == 0xFE0F) then
            j = i
            while true do
                local nx = cps[j + 1]
                if nx == 0xFE0F or (nx and is_skin(nx)) or (nx and is_tag(nx)) then
                    j = j + 1
                elseif nx == 0x200D and cps[j + 2] and cps[j + 2] > 0x7F then
                    j = j + 2
                else
                    break
                end
            end
        end
        if j then
            flush()
            local seq = {}
            for k = i, j do seq[#seq + 1] = cps[k] end
            out[#out + 1] = {emoji = table.concat(raw, "", i, j), name = M.name(seq)}
            i = j + 1
        else
            buf[#buf + 1] = raw[i]
            i = i + 1
        end
    end
    flush()
    return out
end

function M.has_emoji(s)
    for _, part in ipairs(M.split(s)) do if part.emoji then return true end end
    return false
end

---------------------------------------------------------------------------
-- Image loading and drawing (needs mpv + LuaJIT)
---------------------------------------------------------------------------

-- opts: overlay_id, on_ready (called when a new image becomes available),
--       mpv_path, curl_path, max_jobs
function M.layer(opts)
    local mp = mp
    local utils = require("mp.utils")
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return nil end

    local L = {}
    local overlay_id = opts.overlay_id or 44
    local mpv_path = opts.mpv_path or "mpv"
    local curl_path = opts.curl_path or "curl"
    local max_jobs = opts.max_jobs or 3
    local cache_dir = mp.command_native({"expand-path", "~~cache/twemoji"})
    local dir_ready = false

    local images = {} -- name -> {state="loading"|"ready"|"failed", px=uint8_t[], gen}
    local queue, running = {}, 0
    local scaled = {}  -- name.."@"..size -> premultiplied BGRA uint8_t[size*size*4]
    local scaled_count = 0
    local shown_key, shown_buf = nil, nil

    local function ensure_dir(cb)
        if dir_ready or utils.file_info(cache_dir) then dir_ready = true return cb() end
        -- cmd's mkdir creates parents; the path is its own argument so mpv does
        -- not wrap it in \"...\" quoting that cmd rejects, and uses
        -- backslashes because cmd reads "/x" as a switch.
        mp.command_native_async({name = "subprocess", playback_only = false,
            capture_stdout = true, capture_stderr = true,
            args = {"cmd", "/d", "/c", "mkdir", (cache_dir:gsub("/", "\\"))}}, function()
            dir_ready = true
            cb()
        end)
    end

    -- Reads a 72x72 straight-alpha BGRA file into a premultiplied buffer.
    local function load_raw(name, path)
        local f = io.open(path, "rb")
        if not f then return false end
        local data = f:read("*a")
        f:close()
        local size = M.SRC * M.SRC * 4
        if not data or #data ~= size then return false end
        local px = ffi.new("uint8_t[?]", size)
        ffi.copy(px, data, size)
        for k = 0, size - 4, 4 do
            local a = px[k + 3]
            if a == 0 then
                px[k], px[k + 1], px[k + 2] = 0, 0, 0
            elseif a < 255 then
                px[k] = math.floor(px[k] * a / 255 + 0.5)
                px[k + 1] = math.floor(px[k + 1] * a / 255 + 0.5)
                px[k + 2] = math.floor(px[k + 2] * a / 255 + 0.5)
            end
        end
        images[name] = {state = "ready", px = px}
        return true
    end

    local function run(args, cb)
        mp.command_native_async({name = "subprocess", args = args, playback_only = false,
            capture_stdout = true, capture_stderr = true}, function(success, res)
            cb(success and res and res.status == 0)
        end)
    end

    local pump
    local function finish(name, ok)
        running = running - 1
        if not ok then images[name] = {state = "failed"} end
        if ok and opts.on_ready then opts.on_ready() end
        pump()
    end

    local function fetch(name)
        local raw = utils.join_path(cache_dir, name .. ".bgra")
        if utils.file_info(raw) and load_raw(name, raw) then return finish(name, true) end
        local png = utils.join_path(cache_dir, name .. ".png.part")
        local function convert()
            run({mpv_path, "--no-config", "--load-scripts=no", "--msg-level=all=no",
                "--audio=no", "--frames=1", "--vf=format=bgra", "--of=rawvideo",
                "--ovc=rawvideo", "--o=" .. raw, "--", png}, function(ok)
                os.remove(png)
                if not (ok and load_raw(name, raw)) then os.remove(raw) return finish(name, false) end
                finish(name, true)
            end)
        end
        local function download(file, retry)
            run({curl_path, "-sfL", "--max-time", "20", "-o", png,
                M.URL:format(M.VERSION, file)}, function(ok)
                if ok then return convert() end
                os.remove(png)
                if retry then return download(retry) end
                finish(name, false)
            end)
        end
        download(name, M.alt_name(name))
    end

    pump = function()
        while running < max_jobs and #queue > 0 do
            local name = table.remove(queue, 1)
            running = running + 1
            ensure_dir(function() fetch(name) end)
        end
    end

    -- "ready", "loading" or "failed"; starts loading on first request.
    function L.state(name)
        local img = images[name]
        if not img then
            images[name] = {state = "loading"}
            queue[#queue + 1] = name
            pump()
            return "loading"
        end
        return img.state
    end

    -- Area-average resample of a premultiplied 72x72 image to size x size.
    local function get_scaled(name, size)
        local key = name .. "@" .. size
        local buf = scaled[key]
        if buf then return buf end
        local src = images[name].px
        if scaled_count >= 256 then scaled, scaled_count = {}, 0 end
        buf = ffi.new("uint8_t[?]", size * size * 4)
        local S = M.SRC
        local r = S / size
        for y = 0, size - 1 do
            local y0, y1 = y * r, (y + 1) * r
            for x = 0, size - 1 do
                local x0, x1 = x * r, (x + 1) * r
                local b, g, rr, a, wsum = 0, 0, 0, 0, 0
                for sy = math.floor(y0), math.min(S - 1, math.ceil(y1) - 1) do
                    local wy = math.min(y1, sy + 1) - math.max(y0, sy)
                    for sx = math.floor(x0), math.min(S - 1, math.ceil(x1) - 1) do
                        local w = wy * (math.min(x1, sx + 1) - math.max(x0, sx))
                        local o = (sy * S + sx) * 4
                        b, g, rr, a = b + src[o] * w, g + src[o + 1] * w,
                            rr + src[o + 2] * w, a + src[o + 3] * w
                        wsum = wsum + w
                    end
                end
                local o = (y * size + x) * 4
                buf[o] = math.floor(b / wsum + 0.5)
                buf[o + 1] = math.floor(g / wsum + 0.5)
                buf[o + 2] = math.floor(rr / wsum + 0.5)
                buf[o + 3] = math.floor(a / wsum + 0.5)
            end
        end
        scaled[key], scaled_count = buf, scaled_count + 1
        return buf
    end

    -- items: {{name=, x=}} with x relative to the left edge, in pixels.
    -- Draws them in one overlay at (x, y) with each image size x size;
    -- opacity 0..1. Redraws only when something changed.
    function L.draw(x, y, size, items, opacity)
        if #items == 0 or size < 4 or opacity <= 0 then return L.clear() end
        x, y = math.floor(x + 0.5), math.floor(y + 0.5)
        local level = math.floor(opacity * 32 + 0.5) -- coarse steps during fades
        local parts = {x, y, size, level}
        for _, it in ipairs(items) do parts[#parts + 1] = it.name .. "@" .. math.floor(it.x + 0.5) end
        local key = table.concat(parts, ",")
        if key == shown_key then return end
        local W = 0
        for _, it in ipairs(items) do W = math.max(W, math.floor(it.x + 0.5) + size) end
        local buf = ffi.new("uint8_t[?]", W * size * 4)
        local mul = level / 32
        for _, it in ipairs(items) do
            local img = get_scaled(it.name, size)
            local ox = math.floor(it.x + 0.5)
            for row = 0, size - 1 do
                local d = (row * W + ox) * 4
                if mul >= 1 then
                    ffi.copy(buf + d, img + row * size * 4, size * 4)
                else
                    local s = row * size * 4
                    for k = 0, size * 4 - 1 do buf[d + k] = math.floor(img[s + k] * mul + 0.5) end
                end
            end
        end
        local addr = "&" .. tostring(ffi.cast("uintptr_t", buf)):gsub("U?LL$", "")
        mp.command_native({"overlay-add", overlay_id, x, y, addr, 0, "bgra", W, size, W * 4})
        shown_key, shown_buf = key, buf -- keep the pixels alive while shown
    end

    function L.clear()
        if shown_key then
            mp.command_native({"overlay-remove", overlay_id})
            shown_key, shown_buf = nil, nil
        end
    end

    return L
end

return M
