-- quality-menu 4.2.1 - 2025-Jun-29
-- https://github.com/christoph-heinrich/mpv-quality-menu
-- Placement: ~~/scripts/quality-menu.lua

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local assdraw = require 'mp.assdraw'
local opt = require('mp.options')
local script_name = mp.get_script_name()

local opts = {
    up_binding = 'UP WHEEL_UP',
    down_binding = 'DOWN WHEEL_DOWN',
    select_binding = 'ENTER MBTN_LEFT',
    close_menu_binding = 'ESC MBTN_RIGHT',

    selected_and_active     = '▶  - ',
    selected_and_inactive   = '●  - ',
    unselected_and_active   = '▷ - ',
    unselected_and_inactive = '○ - ',

    scale_playlist_by_window = true,

    style_ass_tags = '{\\fnmonospace\\fs25\\bord1}',

    -- LOCAL ADDITIONS (used by draw_menu): a title above the list, a
    -- key-hint line below it, and control over where the list sits.
    menu_position = 'center',
    filter_by_available = true,
    show_header = true,
    show_hints = true,
    header_ass_tags = '{\\fs15\\bord1.5\\1c&H07C1FF&\\3c&H101010&}',
    hint_ass_tags = '{\\fs12\\bord1.2\\1c&H9A9A9A&\\3c&H101010&}',
    hint_text = 'UP/DOWN  move      ENTER  select      ESC  close',

    shift_x = 0,
    shift_y = 0,

    text_padding_x = 5,
    text_padding_y = 10,

    curtain_opacity = 0.7,
    menu_timeout = 6,
    fetch_formats = true,

    quality_strings_video = [[
    [
    {"4320p" : "bestvideo[height<=?4320]"},
    {"2160p" : "bestvideo[height<=?2160]"},
    {"1440p" : "bestvideo[height<=?1440]"},
    {"1080p" : "bestvideo[height<=?1080]"},
    {"720p" : "bestvideo[height<=?720]"},
    {"480p" : "bestvideo[height<=?480]"},
    {"360p" : "bestvideo[height<=?360]"},
    {"240p" : "bestvideo[height<=?240]"},
    {"144p" : "bestvideo[height<=?144]"}
    ]
    ]],
    quality_strings_audio = [[
    [
    {"default" : "bestaudio/best"}
    ]
    ]],

    start_with_menu = false,
    include_unknown = false,
    hide_identical_columns = true,

    columns_video = '-resolution,frame_rate,dynamic_range|language,bitrate_total,size,-codec_video,-codec_audio',
    columns_audio = 'audio_sample_rate,bitrate_total|size,language,-codec_audio',
    sort_video = 'height,fps,tbr,size,format_id',
    sort_audio = 'asr,tbr,size,format_id',
}
opt.read_options(opts, 'quality-menu')

do
    local function parse_predefined(option_string, option_name)
        local json, error = utils.parse_json(option_string)
        if error then
            msg.error('Error while parsing JSON of option ' .. option_name .. ': ' .. error)
            return {}
        end
        local formats = {}
        for i, format in ipairs(json) do
            local label, format_string = next(format)
            formats[i] = {
                label = label,
                title = label,
                id = format_string,
            }
        end
        return formats
    end

    opts.predefined_data = {
        video_formats = parse_predefined(opts.quality_strings_video, 'quality_strings_video'),
        audio_formats = parse_predefined(opts.quality_strings_audio, 'quality_strings_audio'),
        video_active_id = nil,
        audio_active_id = nil,
    }
end

opts.font_size = tonumber(opts.style_ass_tags:match('\\fs(%d+%.?%d*)')) or mp.get_property_number('osd-font-size') or 25
opts.curtain_opacity = math.max(math.min(opts.curtain_opacity, 1), 0)

local function string_split(input, separator)
    if separator == nil then separator = '%s' end
    local t = {}
    for str in string.gmatch(input, '([^' .. separator .. ']+)') do
        table.insert(t, str)
    end
    return t
end

local function strip_minus(strings)
    local stripped_list = {}
    local had_minus = {}
    for i, val in ipairs(strings) do
        if string.sub(val, 1, 1) == '-' then
            val = string.sub(val, 2)
            had_minus[val] = true
        end
        stripped_list[i] = val
    end
    return stripped_list, had_minus
end

do
    local function parse_columns(column_definition)
        local columns, columns_align_left = strip_minus(string_split(column_definition, '|,'))
        local title_hint = string_split(column_definition, '|')
        local title, title_align_left = strip_minus(string_split(title_hint[1], ','))

        local hint = nil
        if title_hint[2] then
            hint = strip_minus(string_split(title_hint[2], ','))
            local n = #hint
            for i = 1, n / 2 do
                hint[i], hint[n - i + 1] = hint[n - i + 1], hint[i]
            end
        end
        return {
            all = columns, all_align_left = columns_align_left,
            title = title, title_align_left = title_align_left,
            hint = hint
        }
    end

    opts.columns_video = parse_columns(opts.columns_video)
    opts.columns_audio = parse_columns(opts.columns_audio)
end

local function reload_resume()
    local reload_duration = mp.get_property_native('duration')
    local time_pos = mp.get_property('time-pos')

    mp.command('playlist-play-index current')

    if reload_duration and reload_duration > 0 and time_pos then
        local function seeker()
            mp.commandv('seek', time_pos, 'absolute+exact')
            mp.unregister_event(seeker)
        end
        mp.register_event('file-loaded', seeker)
    end
end

local states = {
    video_menu = { type = 'video', type_capitalized = 'Video', name = 'video_menu', is_video = true },
    audio_menu = { type = 'audio', type_capitalized = 'Audio', name = 'audio_menu', is_video = false },
    video_fetching = { type = 'video', type_capitalized = 'Video', name = 'video_fetching', is_video = true },
    audio_fetching = { type = 'audio', type_capitalized = 'Audio', name = 'audio_fetching', is_video = false },
}
states.video_menu.to_fetching = states.video_fetching
states.video_menu.to_menu = states.video_menu
states.video_menu.to_other_type = states.audio_menu
states.audio_menu.to_fetching = states.audio_fetching
states.audio_menu.to_menu = states.audio_menu
states.audio_menu.to_other_type = states.video_menu
states.video_fetching.to_fetching = states.video_fetching
states.video_fetching.to_menu = states.video_menu
states.video_fetching.to_other_type = states.audio_fetching
states.audio_fetching.to_fetching = states.audio_fetching
states.audio_fetching.to_menu = states.audio_menu
states.audio_fetching.to_other_type = states.video_fetching

local open_menu_state = nil
local current_url = nil
local destructor = nil

local menu_open
local menu_close
local video_formats_toggle
local audio_formats_toggle

local osd = mp.create_osd_overlay('ass-events')

local function hide_osd()
    osd.data = ''
    osd:update()
    osd.hidden = true
    osd:update()
end

local osd_timer = mp.add_timeout(1, function() menu_close() end)
osd_timer:kill()

local function osd_message(message, time)
    osd.res_x = 1280
    osd.res_y = 720
    osd.hidden = false
    osd.data = message
    osd:update()
    osd_timer.timeout = time
    osd_timer:kill()
    osd_timer:resume()
end

local function process_json(json)
    local function is_video(format)
        return (opts.include_unknown or format.vcodec) and format.vcodec ~= 'none' or false
    end

    local function is_audio(format)
        return (opts.include_unknown or format.acodec) and format.acodec ~= 'none' or false
    end

    local requested_video = nil
    local requested_audio = nil
    local requested_formats = json.requested_formats or json.requested_downloads or {}
    for _, format in ipairs(requested_formats) do
        if is_video(format) then
            requested_video = format.format_id
        elseif is_audio(format) then
            requested_audio = format.format_id
        end
    end

    local video_formats = {}
    local audio_formats = {}
    local all_formats = {}
    for i = #json.formats, 1, -1 do
        local format = json.formats[i]
        if is_video(format) then
            video_formats[#video_formats + 1] = format
            all_formats[#all_formats + 1] = format
        elseif is_audio(format) then
            audio_formats[#audio_formats + 1] = format
            all_formats[#all_formats + 1] = format
        end
    end

    local function populate_special_fields(format)
        format.size = format.filesize or format.filesize_approx
        format.frame_rate = format.fps
        format.bitrate_total = format.tbr
        format.bitrate_video = format.vbr
        format.bitrate_audio = format.abr
        format.codec_video = format.vcodec
        format.codec_audio = format.acodec
        format.audio_sample_rate = format.asr
    end

    for _, format in ipairs(all_formats) do
        populate_special_fields(format)
    end

    local sort_video, reverse_video = strip_minus(string_split(opts.sort_video, ','))
    local sort_audio, reverse_audio = strip_minus(string_split(opts.sort_audio, ','))

    local function comp(properties, reverse)
        return function(a, b)
            for _, prop in ipairs(properties) do
                local a_val = a[prop]
                local b_val = b[prop]
                if a_val and b_val and type(a_val) ~= 'table' and a_val ~= b_val then
                    if reverse[prop] then
                        return a_val < b_val
                    else
                        return a_val > b_val
                    end
                end
            end
            return false
        end
    end

    if #sort_video > 0 then
        table.sort(video_formats, comp(sort_video, reverse_video))
    end
    if #sort_audio > 0 then
        table.sort(audio_formats, comp(sort_audio, reverse_audio))
    end

    local function scale_filesize(size)
        if size == nil then return '' end
        local counter = 0
        while size > 1024 do
            size = size / 1024
            counter = counter + 1
        end
        if counter >= 3 then return string.format('%.1fGiB', size)
        elseif counter >= 2 then return string.format('%.1fMiB', size)
        elseif counter >= 1 then return string.format('%.1fKiB', size)
        else return string.format('%.1fB  ', size)
        end
    end

    local function scale_bitrate(bitrate)
        if bitrate == nil then return '' end
        local counter = 0
        while bitrate > 1000 do
            bitrate = bitrate / 1000
            counter = counter + 1
        end
        if counter >= 2 then return string.format('%.1fGbps', bitrate)
        elseif counter >= 1 then return string.format('%.1fMbps', bitrate)
        else return string.format('%.1fKbps', bitrate)
        end
    end

    local function format_special_fields(format)
        local size_prefix = not format.filesize and format.filesize_approx and '~' or ''
        format.size = (size_prefix) .. scale_filesize(format.size)
        format.frame_rate = format.fps and format.fps .. 'fps' or ''
        format.bitrate_total = scale_bitrate(format.tbr)
        format.bitrate_video = scale_bitrate(format.vbr)
        format.bitrate_audio = scale_bitrate(format.abr)
        format.codec_video = format.vcodec == nil and 'unknown' or format.vcodec == 'none' and '' or format.vcodec
        format.codec_audio = format.acodec == nil and 'unknown' or format.acodec == 'none' and '' or format.acodec
        format.audio_sample_rate = format.asr and tostring(format.asr) .. 'Hz' or ''
    end

    for _, format in ipairs(all_formats) do
        format_special_fields(format)
    end

    local function convert_to_format(raw_formats, properties)
        local formats = {}
        for i, format in ipairs(raw_formats) do
            local props = {}
            for _, prop in ipairs(properties) do
                props[prop] = tostring(format[prop] or '')
            end
            formats[i] = { properties = props, id = format.format_id }
        end
        return formats
    end

    return {
        video_formats = convert_to_format(video_formats, opts.columns_video.all),
        audio_formats = convert_to_format(audio_formats, opts.columns_audio.all),
        video_active_id = requested_video,
        audio_active_id = requested_audio,
    }
end

local function get_url()
    local path, n = mp.get_property('path'), nil
    if not path then return nil end
    path, n = path:gsub('^ytdl://', '')
    if n > 0 then return path end

    local function is_url(str)
        return nil ~=
            str:match(
                '^[%w]-://[-a-zA-Z0-9@:%._\\+~#=]+%.' ..
                '[a-zA-Z0-9()][a-zA-Z0-9()]?[a-zA-Z0-9()]?[a-zA-Z0-9()]?[a-zA-Z0-9()]?[a-zA-Z0-9()]?' ..
                '[-a-zA-Z0-9()@:%_\\+.~#?&/=]*')
    end

    return is_url(path) and path or nil
end

local uosc_available = false
local url_data = {}
-- LOCAL ADDITION: url -> real maximum height reported by yt-dlp.
local url_max_height = {}

local function uosc_set_format_counts()
    if not uosc_available then return end

    local data = url_data[current_url]
    if data then
        mp.commandv('script-message-to', 'uosc', 'set', 'vformats', #data.video_formats)
        mp.commandv('script-message-to', 'uosc', 'set', 'aformats', #data.audio_formats)
    else
        mp.commandv('script-message-to', 'uosc', 'set', 'vformats', 0)
        mp.commandv('script-message-to', 'uosc', 'set', 'aformats', 0)
    end
end

local function process_json_string(json)
    local json_table, err = utils.parse_json(json)
    if (json_table == nil) then
        osd_message('fetching formats failed...', 2)
        if err == nil then err = 'unexpected error occurred' end
        msg.error('failed to parse JSON data: ' .. err)
        return
    end
    if json_table.formats == nil then return end
    return process_json(json_table)
end

local function sanitize_format_id(id, formats)
    return id or (formats[1] or {}).id or ''
end

local function format_string(video_id, audio_id)
    if #video_id > 0 and #audio_id > 0 then return video_id .. '+' .. audio_id
    elseif #video_id > 0 then return video_id
    elseif #audio_id > 0 then return audio_id
    else return '' end
end

local function set_format(url, video_format, audio_format)
    if (url_data[url].video_active_id ~= video_format or url_data[url].audio_active_id ~= audio_format) then
        url_data[url].video_active_id = video_format
        url_data[url].audio_active_id = audio_format
        if url == mp.get_property('path') then reload_resume() end
    end
end

-- Forward declaration: the select callback inside text_menu_open closes over
-- this upvalue. Without it the call resolved to an undefined global, because
-- the local implementation is declared further down the file.
local handle_local_select

-- is_local: the local-file resolution menu has no 'Auto' row (that row only clears the
-- streaming ytdl-format override, which means nothing for a file on disk).
local function text_menu_open(formats, active_format, menu_type, is_local)
    local active = 0
    local selected = 1
    for i, format in ipairs(formats) do
        if format.id == active_format then
            active = i
            selected = active
            break
        end
    end
    if active_format == '' and not is_local then
        active = #formats + 1
        selected = active
    end

    local function choose_prefix(i)
        if i == selected and i == active then return opts.selected_and_active
        elseif i == selected then return opts.selected_and_inactive end

        if i ~= selected and i == active then return opts.unselected_and_active
        elseif i ~= selected then return opts.unselected_and_inactive end
        return '> '
    end

    local width, height
    local margin_top, margin_bottom = 0, 0
    local extra_rows = is_local and 1 or 2 -- [Auto +] Switch-to row
    local num_options = #formats > 0 and #formats + extra_rows or 1

    local function get_scrolled_lines()
        local output_height = height - opts.text_padding_y * 2 - margin_top * height - margin_bottom * height
        local screen_lines = math.max(math.floor(output_height / opts.font_size), 1)
        local max_scroll = math.max(num_options - screen_lines, 0)
        return math.min(math.max(selected - math.ceil(screen_lines / 2), 0), max_scroll)
    end

    local function draw_menu()
        local ass = assdraw.ass_new()

        if opts.curtain_opacity > 0 then
            local alpha = 255 - math.ceil(255 * opts.curtain_opacity)
            ass.text = string.format('{\\pos(0,0)\\rDefault\\an7\\1c&H000000&\\alpha&H%X&}', alpha)
            ass:draw_start()
            ass:rect_cw(0, 0, width, height)
            ass:draw_stop()
            ass:new_event()
        end

        local scrolled_lines = get_scrolled_lines()
        local clip_top = math.floor(margin_top * height + 0.5)
        local clip_bottom = math.floor((1 - margin_bottom) * height + 0.5)
        
        -- Centered and dynamically spaced based on ui margins
        local bottom_spacing = 40
        local output_height = height - opts.text_padding_y * 2 - margin_top * height - margin_bottom * height
        local screen_lines = math.max(math.floor(output_height / opts.font_size), 1)
        local max_scroll = math.max(num_options - screen_lines, 0)
        
        local pos_x = opts.shift_x + (width / 2)
        -- menu_position: 'center' floats the list in the middle of the
        -- visible area, 'bottom' keeps the original placement above the OSC.
        local pos_y
        if opts.menu_position == 'bottom' then
            pos_y = clip_bottom - bottom_spacing
        else
            pos_y = (clip_top + clip_bottom) / 2 + (num_options * opts.font_size) / 2
        end
        pos_y = pos_y + ((max_scroll - scrolled_lines) * opts.font_size)

        local clipping_coordinates = '0,' .. clip_top .. ',' .. width .. ',' .. clip_bottom
        local clip_tag = '{\\rDefault\\an2\\q2\\clip(' .. clipping_coordinates .. ')}'

        -- Title and hints are drawn as their OWN ass events at absolute
        -- positions, so the scroll maths above is left untouched. The list is
        -- bottom-centred (\an2), so pos_y is the bottom of the whole block.
        if opts.show_header then
            local list_top = pos_y - num_options * opts.font_size
            ass:pos(pos_x, list_top - opts.font_size * 0.4)
            ass:append(clip_tag .. opts.style_ass_tags .. opts.header_ass_tags ..
                menu_type.type_capitalized .. ' Quality')
            ass:new_event()
        end
        if opts.show_hints then
            ass:pos(pos_x, pos_y + opts.font_size * 0.6)
            ass:append('{\\rDefault\\an8\\q2\\clip(' .. clipping_coordinates .. ')}' ..
                opts.style_ass_tags .. opts.hint_ass_tags .. opts.hint_text)
            ass:new_event()
        end

        ass:pos(pos_x, pos_y)
        ass:append(clip_tag .. opts.style_ass_tags)

        if #formats > 0 then
            for i, format in ipairs(formats) do
                ass:append(choose_prefix(i) .. format.label .. '\\N')
            end
            -- LOCAL PATCH: 'Disabled' reads as "turn the video off". It only
            -- clears the ytdl-format override, so name it for what it does.
            if not is_local then
                ass:append(choose_prefix(#formats + 1) .. 'Auto  (mpv default)\\N')
            end
            ass:append(choose_prefix(num_options) .. 'Switch to ' ..
                menu_type.to_other_type.type_capitalized .. ' menu')
        else
            ass:append('no formats found\\N')
            ass:append(opts.selected_and_inactive .. 'Switch to ' ..
                menu_type.to_other_type.type_capitalized .. ' menu')
        end

        osd.data = ass.text
        osd:update()
    end

    local function update_dimensions()
        local _, h, aspect = mp.get_osd_size()
        if opts.scale_playlist_by_window then h = 720 end
        height = h
        width = height * aspect
        osd.res_y = height
        osd.res_x = width
        draw_menu()
    end

    local update_margins = function(_, val)
        if not val then
            val = mp.get_property_native('user-data/osc/margins')
        end
        if val then
            margin_top = val.t
            margin_bottom = val.b
        else
            margin_top = 0
            margin_bottom = 0
        end
        draw_menu()
    end
    mp.observe_property('user-data/osc/margins', 'native', update_margins)

    update_dimensions()
    update_margins()
    mp.observe_property('osd-dimensions', 'native', update_dimensions)

    local function selected_move(amount)
        selected = selected + amount
        if selected < 1 then selected = num_options
        elseif selected > num_options then selected = 1 end
        if osd_timer then
            osd_timer:kill()
            osd_timer:resume()
        end
        draw_menu()
    end

    local function bind_keys(keys, name, func, opts)
        if not keys then
            mp.add_forced_key_binding(keys, name, func, opts)
            return
        end
        local i = 1
        for key in keys:gmatch('[^%s]+') do
            local prefix = i == 1 and '' or i
            mp.add_forced_key_binding(key, name .. prefix, func, opts)
            i = i + 1
        end
    end

    local function unbind_keys(keys, name)
        if not keys then
            mp.remove_key_binding(name)
            return
        end
        local i = 1
        for key in keys:gmatch('[^%s]+') do
            local prefix = i == 1 and '' or i
            mp.remove_key_binding(name .. prefix)
            i = i + 1
        end
    end

    if open_menu_state and open_menu_state == open_menu_state.to_menu and destructor then destructor() end
    destructor = function()
        unbind_keys(opts.up_binding, 'move_up')
        unbind_keys(opts.down_binding, 'move_down')
        unbind_keys(opts.select_binding, 'select')
        unbind_keys(opts.close_menu_binding, 'close')
        mp.unobserve_property(update_dimensions)
        mp.unobserve_property(update_margins)
    end

    osd_timer:kill()
    if opts.menu_timeout > 0 then
        osd_timer.timeout = opts.menu_timeout
        osd_timer:resume()
    end

    bind_keys(opts.up_binding, 'move_up', function() selected_move( -1) end, { repeatable = true })
    bind_keys(opts.down_binding, 'move_down', function() selected_move(1) end, { repeatable = true })
    bind_keys(opts.close_menu_binding, 'close', menu_close)
    bind_keys(opts.select_binding, 'select', function()
        if selected == num_options then
            mp.unobserve_property(update_dimensions)
            mp.unobserve_property(update_margins)
            if menu_type.is_video then audio_formats_toggle()
            else video_formats_toggle() end
            return
        end
        menu_close()
        if selected == active then return end
        if current_url == nil then
            handle_local_select(formats[selected])
            return
        end

        local video_id, audio_id
        local id = formats[selected] and formats[selected].id or ''
        local data = url_data[current_url]
        if menu_type.is_video then
            video_id = id
            audio_id = sanitize_format_id(data.audio_active_id, data.audio_formats)
        else
            video_id = sanitize_format_id(data.video_active_id, data.video_formats)
            audio_id = id
        end
        set_format(current_url, video_id, audio_id)
    end)

    osd.hidden = false
    draw_menu()
end

local function uosc_show_menu(menu, menu_type)
    local json = utils.format_json(menu)
    if open_menu_state == menu_type then mp.commandv('script-message-to', 'uosc', 'update-menu', json)
    else mp.commandv('script-message-to', 'uosc', 'open-menu', json) end
end

local function uosc_menu_open(formats, active_format, menu_type)
    local menu = {
        title = menu_type.type_capitalized .. ' Formats',
        items = {},
        type = 'quality-menu-' .. menu_type.name,
        keep_open = true,
        on_close = {
            'script-message-to',
            script_name,
            'uosc-menu-closed',
            menu_type.name,
        }
    }

    menu.items[#menu.items + 1] = {
        title = menu_type.to_other_type.type_capitalized,
        italic = true,
        bold = true,
        hint = 'open menu',
        value = {
            'script-message-to',
            script_name,
            menu_type.to_other_type.type .. '_formats_toggle',
        },
    }
    menu.items[#menu.items + 1] = {
        title = 'Auto  (mpv default)',
        italic = true,
        muted = true,
        hint = '—',
        active = active_format == '',
        value = {
            'script-message-to',
            script_name,
            menu_type.type .. '-format-set',
            current_url,
            '',
        }
    }

    for _, format in ipairs(formats) do
        menu.items[#menu.items + 1] = {
            title = format.title,
            hint = format.hint,
            active = format.id == active_format,
            value = {
                'script-message-to',
                script_name,
                menu_type.type .. '-format-set',
                current_url,
                format.id,
            }
        }
    end

    uosc_show_menu(menu, menu_type)
    destructor = function()
        mp.commandv('script-message-to', 'uosc', 'close-menu', menu.type)
    end
end

local function identical_for_all(formats, properties)
    local function all_formats_same_value(formats, prop)
        local first_value = nil
        for _, format in ipairs(formats) do
            first_value = first_value or format.properties[prop]
            if format.properties[prop] ~= first_value then return false end
        end
        return true
    end

    local identical_props = {}
    for _, prop in ipairs(properties) do
        identical_props[prop] = all_formats_same_value(formats, prop)
    end
    return identical_props
end

local function format_table(formats, columns, column_align_left)
    local column_widths = {}
    for _, format in pairs(formats) do
        for col, prop in ipairs(columns) do
            local width = format.properties[prop]:len()
            if not column_widths[col] or column_widths[col] < width then
                column_widths[col] = width
            end
        end
    end

    local identical_columns = #formats < 2 and {} or identical_for_all(formats, columns)

    local show_columns = {}
    for i, width in ipairs(column_widths) do
        local prop = columns[i]
        if width > 0 and not (opts.hide_identical_columns and identical_columns[prop]) then
            show_columns[#show_columns + 1] = {
                prop = prop,
                width = width,
                align_left = column_align_left[prop]
            }
        end
    end

    local spacing = 2
    local rows = {}
    for i, format in ipairs(formats) do
        local row = {}
        for j, column in ipairs(show_columns) do
            local width = math.min(column.width * (column.align_left and -1 or 1), 99)
            row[j] = string.format('%' .. width .. 's', format.properties[column.prop] or '')
        end
        rows[i] = table.concat(row, string.format('%' .. spacing .. 's', '')):gsub('%s+$', '')
    end
    return rows
end

local function format_csv(formats, columns)
    local identical_props = #formats < 2 and {} or identical_for_all(formats, columns)
    local hints = {}
    for i, format in ipairs(formats) do
        local row = {}
        for _, prop in ipairs(columns) do
            local val = format.properties[prop]
            if #val > 0 and not (opts.hide_identical_columns and identical_props[prop]) then
                row[#row + 1] = val
            end
        end
        hints[i] = table.concat(row, ', ')
    end
    return hints
end

local function ensure_menu_data_filled(formats, menu_type)
    if uosc_available then
        if formats[1] and formats[1].title == nil then
            local columns = menu_type.is_video and opts.columns_video or opts.columns_audio
            local titles = format_table(formats, columns.title, columns.title_align_left)
            local hints = {}
            if columns.hint then hints = format_csv(formats, columns.hint) end

            for i, format in ipairs(formats) do
                format.title = titles[i]
                format.hint = hints[i]
            end
        end
    else
        if formats[1] and formats[1].label == nil then
            local columns = menu_type.is_video and opts.columns_video or opts.columns_audio
            local labels = format_table(formats, columns.all, columns.all_align_left)
            for i, format in ipairs(formats) do format.label = labels[i] end
        end
    end
end

local function loading_message(menu_type)
    menu_type = menu_type.to_fetching
    if uosc_available then
        if open_menu_state and open_menu_state == menu_type then return end
        local menu = {
            title = menu_type.type_capitalized .. ' Formats',
            items = { { icon = 'spinner', selectable = false, value = 'ignore' } },
            type = 'quality-menu-' .. menu_type.name,
            keep_open = true,
            on_close = { 'script-message-to', script_name, 'uosc-menu-closed', menu_type.name }
        }
        uosc_show_menu(menu, menu_type)
        destructor = function()
            mp.commandv('script-message-to', 'uosc', 'close-menu', menu.type)
        end
    else
        osd_message('fetching available ' .. menu_type.type .. ' formats...', 60)
    end
    open_menu_state = menu_type
end

function menu_open(menu_type)
    if not current_url then return end
    menu_type = menu_type.to_menu

    local data = url_data[current_url]
    if not data then
        if opts.fetch_formats then
            loading_message(menu_type)
            return
        end
        data = {}
        for k, v in pairs(opts.predefined_data) do data[k] = v end
        -- Drop curated entries above what this video actually has. Heights come
        -- from the selector itself ("bestvideo[height<=2160]"), so an entry
        -- without a height filter is always kept.
        local max_h = url_max_height[current_url]
        if max_h then
            local kept = {}
            for _, f in ipairs(opts.predefined_data.video_formats) do
                local h = tonumber(tostring(f.id):match('height<=%s*(%d+)'))
                if not h or h <= max_h then kept[#kept + 1] = f end
            end
            if #kept > 0 then data.video_formats = kept end
        end
        url_data[current_url] = data
    end
    local formats = menu_type.is_video and data.video_formats or data.audio_formats
    local active_format
    if menu_type.is_video then active_format = data.video_active_id
    else active_format = data.audio_active_id end

    ensure_menu_data_filled(formats, menu_type)
    if uosc_available then uosc_menu_open(formats, active_format, menu_type)
    else text_menu_open(formats, active_format, menu_type) end
    open_menu_state = menu_type
end

function menu_close()
    if destructor then
        destructor()
        destructor = nil
    end
    if not osd.hidden then hide_osd() end
    open_menu_state = nil
end

-- Local-file resolution choices, YouTube style: 1080p / 720p / 480p ...
-- A file on disk has one fixed resolution, so lower choices are produced by
-- downscaling inside the filter chain. With zero-copy d3d11va the frames live
-- in GPU textures that the software 'scale' filter cannot read (the graph
-- fails to configure), so the GPU video processor (d3d11vpp) does the resize
-- there; software/copy-back decoding uses the ordinary 'scale' filter.
local RES_LABEL = '@qmres'
local standard_heights = { 2160, 1440, 1080, 720, 480, 360, 240, 144 }
local local_target = 0 -- 0 = original; otherwise the chosen nominal height

local function res_name(h)
    if h >= 2160 then return h .. "p (4K)" end
    if h >= 1440 then return h .. "p (2K)" end
    return h .. "p"
end

-- Nominal height of the decoded source, using the same long/short-edge rule
-- as the Tethys label so 1920x800 reads as 1080p and 1080x1920 as 1080p.
local function source_nominal(w, h)
    local long, short = math.max(w, h), math.min(w, h)
    for _, sh in ipairs(standard_heights) do
        if long >= sh * 16 / 9 * 0.94 or short >= sh * 0.94 then return sh end
    end
    return short
end

-- Scale factor for a nominal height: whichever edge is the binding limit,
-- which is how streaming sites size letterboxed and vertical encodes.
local function res_factor(w, h, target)
    local long, short = math.max(w, h), math.min(w, h)
    return math.min(target / short, (target * 16 / 9) / long)
end

local function apply_local_resolution(target)
    mp.commandv('vf', 'remove', RES_LABEL)
    local_target = target
    if target == 0 then return end
    local vp = mp.get_property_native('video-params')
    if not vp or not vp.w then return end
    local f = res_factor(vp.w, vp.h, target)
    if mp.get_property('hwdec-current') == 'd3d11va' then
        mp.commandv('vf', 'add', ('%s:d3d11vpp=scale=%.4f'):format(RES_LABEL, f))
    else
        -- Round to even sizes: 4:2:0 chroma needs both dimensions even.
        local w = math.floor(vp.w * f / 2 + 0.5) * 2
        local h = math.floor(vp.h * f / 2 + 0.5) * 2
        mp.commandv('vf', 'add', ('%s:scale=w=%d:h=%d'):format(RES_LABEL, w, h))
    end
end

-- vf is a global player option, so a downscale chosen for one file would
-- silently carry over to the next. Each file starts at its original size.
mp.register_event('start-file', function()
    if local_target ~= 0 then apply_local_resolution(0) end
end)
-- Alt+H flips between d3d11va and software decoding; the filter that fits one
-- path fails on the other, so rebuild it for the new decoder.
mp.observe_property('hwdec-current', 'string', function()
    if local_target ~= 0 then apply_local_resolution(local_target) end
end)

local function build_local_video_formats()
    local formats = {}
    local active_id = ""
    local vp = mp.get_property_native("video-params")
    if vp and vp.w and vp.h and vp.w > 0 then
        local source = source_nominal(vp.w, vp.h)
        formats[1] = { id = "res-0", label = res_name(source) .. "  (original)" }
        for _, sh in ipairs(standard_heights) do
            -- Only real downscales: skip anything within ~5% of the source.
            if res_factor(vp.w, vp.h, sh) < 0.95 then
                formats[#formats + 1] = { id = "res-" .. sh, label = res_name(sh) }
            end
        end
        active_id = "res-" .. local_target
    end

    -- Only offer track switching when there is actually a choice; cover art
    -- counts as a video track in mpv but is never a useful pick here.
    local video_tracks = {}
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "video" and not t.albumart then video_tracks[#video_tracks + 1] = t end
    end
    if #video_tracks > 1 then
        for _, vt in ipairs(video_tracks) do
            formats[#formats + 1] = {
                id = "track-" .. tostring(vt.id),
                label = "Video track: " .. (vt.title or vt.lang or ("#" .. tostring(vt.id))) ..
                    (vt.selected and "  (playing)" or ""),
            }
        end
    end

    return formats, active_id
end

local function build_local_audio_formats()
    local tracks = mp.get_property_native("track-list") or {}
    local formats = {}
    local active_id = ""
    for _, t in ipairs(tracks) do
        if t.type == "audio" then
            local label = string.format("Audio %d: %s [%s] %s",
                t.id,
                t.title or ("Track " .. t.id),
                t.lang or "und",
                t.codec or ""
            )
            table.insert(formats, {
                id = "audio-" .. tostring(t.id),
                label = label
            })
            if t.selected then
                active_id = "audio-" .. tostring(t.id)
            end
        end
    end
    if #formats == 0 then
        formats[1] = { id = "none", label = "No audio tracks found" }
    end
    return formats, active_id
end

-- Assigns the forward-declared upvalue above text_menu_open (not a new local).
function handle_local_select(format)
    if not format then return end
    local id = format.id or ""

    local target = tonumber(id:match("^res%-(%d+)$"))
    if target then
        apply_local_resolution(target)
        mp.osd_message("Quality: " .. format.label, 2)
        return
    end

    local tid = tonumber(id:match("^track%-(%d+)"))
    if tid then
        mp.set_property_number("vid", tid)
        mp.osd_message("Video track: " .. tid, 2)
        return
    end
    local aid = tonumber(id:match("^audio%-(%d+)"))
    if aid then
        mp.set_property_number("aid", aid)
        mp.osd_message("Audio track: " .. aid, 2)
    end
end

local function local_menu_open(menu_type)
    menu_type = menu_type.to_menu
    local formats, active_format
    if menu_type.is_video then
        formats, active_format = build_local_video_formats()
    else
        formats, active_format = build_local_audio_formats()
    end

    text_menu_open(formats, active_format, menu_type, true)
    open_menu_state = menu_type
end

local function toggle_menu(menu_type)
    if open_menu_state and open_menu_state.type == menu_type.type then
        menu_close()
        return
    end

    if current_url == nil then
        local path = mp.get_property('path')
        if path and path ~= '' then
            local_menu_open(menu_type)
            return
        end
        if uosc_available then
            if menu_type.is_video then mp.commandv('script-binding', 'uosc/video')
            else mp.commandv('script-binding', 'uosc/audio') end
        end
        return
    end

    menu_open(menu_type)
end

function video_formats_toggle() toggle_menu(states.video_menu) end
function audio_formats_toggle() toggle_menu(states.audio_menu) end

mp.add_key_binding(nil, 'video_formats_toggle', video_formats_toggle)
mp.add_key_binding(nil, 'audio_formats_toggle', audio_formats_toggle)
mp.add_key_binding(nil, 'reload', reload_resume)

mp.register_event('start-file', function()
    local new_url = get_url()
    local url_changed = current_url ~= new_url
    current_url = new_url
    uosc_set_format_counts()

    if not new_url then return menu_close() end
    if opts.start_with_menu and url_changed or open_menu_state then
        menu_open(open_menu_state or states.video_menu)
    end
end)

mp.add_hook('on_load', 9, function()
    local path = mp.get_property('path')
    local data = url_data[path]
    if not (data and data.video_active_id and data.audio_active_id) then return end
    local format = format_string(data.video_active_id, data.audio_active_id)
    mp.set_property('file-local-options/ytdl-format', format)
end)

mp.register_script_message('video-format-set', function(url, format_id)
    menu_close()
    local data = url_data[url]
    set_format(url, format_id, sanitize_format_id(data.audio_active_id, data.audio_formats))
end)

mp.register_script_message('audio-format-set', function(url, format_id)
    menu_close()
    local data = url_data[url]
    set_format(url, sanitize_format_id(data.video_active_id, data.video_formats), format_id)
end)

mp.register_script_message('uosc-version', function(version)
    local function semver_comp(v1, v2)
        local v1_iterator = v1:gmatch('%d+')
        local v2_iterator = v2:gmatch('%d+')
        for v2_num_str in v2_iterator do
            local v1_num_str = v1_iterator()
            if not v1_num_str then return true end
            local v1_num = tonumber(v1_num_str)
            local v2_num = tonumber(v2_num_str)
            if v1_num < v2_num then return true end
            if v1_num > v2_num then return false end
        end
        return false
    end

    local min_version = '4.6.0'
    uosc_available = not semver_comp(version, min_version)
    if not uosc_available then return end
    uosc_set_format_counts()
    mp.commandv('script-message-to', 'uosc', 'overwrite-binding', 'stream-quality', 'script-binding ' .. script_name .. '/video_formats_toggle')
    mp.register_script_message('uosc-menu-closed', function(name)
        if open_menu_state and open_menu_state.name == name then
            destructor = nil
            menu_close()
        end
    end)
end)
mp.commandv('script-message-to', 'uosc', 'get-version', mp.get_script_name())

mp.observe_property('user-data/mpv/ytdl/json-subprocess-result', 'native', function(_, ytdl_result)
    if not ytdl_result then return end
    -- LOCAL PATCH: honour fetch_formats here too.
    -- mpv's own ytdl_hook publishes the full yt-dlp JSON to this property on
    -- every stream it opens, for free. Without this guard the callback below
    -- fills url_data[current_url] with the REAL format list regardless of the
    -- fetch_formats setting, and menu_open() (which only falls back to
    -- opts.predefined_data when url_data[current_url] is nil) then never shows
    -- the curated quality_strings_video list. fetch_formats=no on its own only
    -- stops the script's *own* extra yt-dlp call, not this one.
    -- Remove this guard if you set fetch_formats=yes.
    if not opts.fetch_formats then
        -- Still learn this video's real maximum height, so menu_open() can trim
        -- the curated list to what the video actually offers (no "8K" entry on
        -- a 4K upload). A pattern scan over the raw JSON is used instead of
        -- parse_json: one linear pass, no format tables built.
        if opts.filter_by_available and current_url and ytdl_result.status == 0 then
            local max_h = 0
            for h in (ytdl_result.stdout or ''):gmatch('"height":%s*(%d+)') do
                h = tonumber(h)
                if h and h > max_h then max_h = h end
            end
            if max_h > 0 then url_max_height[current_url] = max_h end
        end
        return
    end
    if not current_url then
        msg.warn('quality-menu: ytdl result received but current_url is nil')
        return
    end

    local json = ytdl_result.stdout
    if ytdl_result.status ~= 0 or json == '' then
        json = nil
        osd_message('fetching formats failed...', 2)
    elseif json then
        local data = url_data[current_url]
        if data == nil then
            data = process_json_string(json)
            url_data[current_url] = data
            uosc_set_format_counts()
        end
        if not data then return end
        if open_menu_state and open_menu_state == open_menu_state.to_fetching then
            menu_open(open_menu_state)
        end
    end
end)