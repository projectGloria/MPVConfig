-- Run from the repository root:
-- .\mpv.com --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tests/regressions.lua
-- Playback, subprocesses, and history writes are mocked; no personal data is read.
local real = require "mp"
local real_utils = require "mp.utils"
local real_io = io
local root = real_utils.join_path(real.get_property("working-directory"), "portable_config/scripts/")
local function fixture(name)
    local s = {props={}, events={}, messages={}, timers={}, jobs={}, commands={}, observers={}, files={}}
    local m = {msg={info=function() end}}
    m.get_property=function(k,d) local v=s.props[k]; if v==nil then return d end; return v end
    m.get_property_bool=m.get_property
    m.get_property_native=m.get_property
    m.get_property_number=m.get_property
    m.set_property=function(k,v) s.props[k]=v end
    m.set_property_native=m.set_property
    m.set_property_bool=m.set_property
    m.set_property_number=m.set_property
    m.command_native=function(a)
        if a[1]=='expand-path' then
            return a[2]:gsub('^~~/script%-modules/',function() return root .. '../script-modules/' end):gsub('^~~/scripts/',function() return root end):gsub('^~~/', 'mock/')
        end
        return {status=0}
    end
    m.command_native_async=function(a,cb) s.jobs[#s.jobs+1]={args=a.args,cb=cb} end
    m.commandv=function(...) s.commands[#s.commands+1]={...} end
    m.command=m.commandv
    m.register_event=function(k,cb) s.events[k]=cb end
    m.unregister_event=function(cb) for k,v in pairs(s.events) do if v==cb then s.events[k]=nil end end end
    m.register_script_message=function(k,cb) s.messages[k]=cb end
    m.add_key_binding=function() end
    m.add_hook=function() end
    m.add_timeout=function(t,cb)
        local x={cb=cb,delay=t,kill=function(self) self.dead=true end}
        s.timers[#s.timers+1]=x
        return x
    end
    m.observe_property=function(k,t,cb) s.observers[#s.observers+1]={k=k,cb=cb} end
    m.unobserve_property=function(cb)
        for _,v in ipairs(s.observers) do if v.cb==cb then v.dead=true end end
    end
    m.osd_message=function() end
    m.create_osd_overlay=function() return {remove=function() end,update=function() end} end
    package.loaded.mp=m
    package.loaded['mp.utils']={
        file_info=function(path) return s.files[path] end,
        parse_json=real_utils.parse_json, format_json=real_utils.format_json,
        join_path=real_utils.join_path,
    }
    package.loaded['mp.options']={read_options=function() end}
    io={open=function(_,mode)
        if mode=='r' then return nil end
        return {write=function() end,close=function() end}
    end}
    dofile(root..name)
    function s:event(k) if self.events[k] then self.events[k]() end end
    function s:fire(delay)
        local pending={}
        for _,timer in ipairs(self.timers) do
            if not timer.dead and timer.delay==delay then pending[#pending+1]=timer end
        end
        for _,timer in ipairs(pending) do timer.dead=true; timer.cb() end
    end
    return s
end

local passed=0
local function check(label, condition)
    assert(condition,label)
    passed=passed+1
    real.msg.info('PASS: '..label)
end
local a='https://www.youtube.com/watch?v=AAAAAAAAAAA'
local b='https://www.youtube.com/watch?v=BBBBBBBBBBB'
local c='https://www.youtube.com/watch?v=CCCCCCCCCCC'
local channel='https://www.youtube.com/@ChannelA'
local result_key='user-data/mpv/ytdl/json-subprocess-result'
local function shared(s,url)
    s.props[result_key]={status=0,stdout=real_utils.format_json({
        webpage_url=url,channel_url=channel,title='Example',channel='Example channel',thumbnail='https://example.com/thumb.jpg'
    })}
end
local function start(s,url)
    s.props.path=url; s:event('start-file'); s:event('file-loaded'); s:fire(3)
end
local function run()
    local s=fixture('youtube-channel-next.lua')
    shared(s,a); start(s,a)
    check('Shared metadata avoids channel resolution subprocess',#s.jobs==1 and s.jobs[1].args[3]=='--flat-playlist')
    s.jobs[1].cb(true,{status=0,stdout=a..'\n'..c..'\n'})
    s.messages['yt-channel-next']()
    check('Next advances beyond current newest upload',s.commands[1][2]==c)
    s.props.path=b; s:event('start-file'); s:event('file-loaded'); s.messages['yt-channel-next']()
    check('New channel never uses old channel during resolution',#s.commands==1)
    s:fire(3)
    check('Metadata belonging to old URL triggers fallback',#s.jobs==2 and s.jobs[2].args[4]=='--print')

    s=fixture('youtube-channel-next.lua'); shared(s,a); start(s,a)
    s.messages['yt-channel-next'](); s.messages['yt-channel-next']()
    check('Navigation joins existing prefetch',#s.jobs==1)
    s.jobs[1].cb(true,{status=0,stdout=a..'\n'..c..'\n'})
    check('Queued next executes once after prefetch',#s.commands==1 and s.commands[1][2]==c)

    s=fixture('youtube-channel-next.lua'); shared(s,a); start(s,a)
    s.messages['yt-channel-next'](); s.props.path=b; s:event('start-file')
    s.jobs[1].cb(true,{status=0,stdout=a..'\n'..c..'\n'})
    check('Old fetch completion cannot change new playback',#s.commands==0)

    s=fixture('youtube-channel-next.lua'); shared(s,a); start(s,a)
    s.messages['yt-channel-next'](); s.jobs[1].cb(false,nil)
    s.messages['yt-channel-next']()
    check('Failed fetch permits retry',#s.jobs==2)

    s=fixture('youtube-channel-next.lua'); shared(s,a); start(s,a)
    s.jobs[1].cb(true,{status=0,stdout=a..'\n'})
    s.messages['yt-channel-next']()
    check('Single-video channel does not reload same video',#s.commands==0)

    s=fixture('clipboard.lua')
    s.props['clipboard/text']=a..'&t=120'; s.messages['clipboard-paste']()
    s.props['clipboard/text']=b; s.messages['clipboard-paste']()
    s.props.path=b; s:event('start-file'); s:event('file-loaded'); s:fire(0.5)
    check('Untimestamped paste cancels previous seek',#s.commands==2)

    s=fixture('clipboard.lua'); s.props.path=b
    s.props['clipboard/text']=a..'&t=120'; s.messages['clipboard-paste']()
    s:event('end-file'); s.props.path=a; s:event('start-file'); s:event('file-loaded'); s:fire(0.5)
    check('Timestamp seek survives replacement of previous file',s.commands[2][1]=='seek' and s.commands[2][2]=='120')

    s=fixture('clipboard.lua'); s.props['clipboard/text']=a..'&t=120'; s.messages['clipboard-paste']()
    s.props.path=a; s:event('start-file'); s:event('file-loaded')
    s.props.path=b; s:event('start-file'); s:fire(0.5)
    check('File switch cancels delayed seek',#s.commands==1)

    s=fixture('pip_manager.lua'); s.props.fullscreen=true; s.messages['pip-managed']()
    s.observers[#s.observers].cb('fullscreen',false)
    local old=s.timers[#s.timers]
    s.messages['pip-managed'](); old.cb()
    check('Cancelled PiP timer cannot enable ontop',s.props.ontop==false and old.dead)
    check('PiP entered from fullscreen exits back to fullscreen',s.props.fullscreen==true)
    s.props.fullscreen=false; s.messages['pip-managed']()
    check('PiP can be entered again after cancellation',s.props.ontop==true)
    s.props.fullscreen=true; s.observers[1].cb('fullscreen',true)
    check('Fullscreen clears active PiP ontop',s.props.ontop==false)

    s=fixture('pip_manager.lua'); s.props.ontop=true; s.props['autofit-larger']='70%x70%'
    s.props['osd-width']=1280; s.props['osd-height']=720
    s.messages['pip-managed']()
    check('PiP lifts autofit cap',s.props['autofit-larger']=='100%x100%' and s.props.ontop==true)
    s.messages['pip-managed'](); s:fire(0.08); s:fire(0.05)
    check('PiP exit restores ontop, autofit and size',s.props.ontop==true
        and s.props['autofit-larger']=='70%x70%' and s.props.geometry=='1280x720')

    s=fixture('pip_manager.lua'); s.props['window-maximized']=true; s.messages['pip-managed']()
    check('PiP from maximized un-maximizes before geometry',s.props['window-maximized']==false and s.props.geometry==nil)
    s.observers[#s.observers].cb(); s:fire(0.1)
    check('PiP geometry applies after leaving maximized',s.props.geometry=='33%+-10+-10')
    s.messages['pip-managed']()
    check('PiP exit returns to maximized with flag still set',s.props['window-maximized']==true
        and s.props['user-data/pip_manager/active']==true)
    s:fire(0.3)
    check('PiP flag clears after maximize settles',s.props['user-data/pip_manager/active']==false)

    s=fixture('playback_preferences.lua'); s.props.path='D:/Media/sample.mp4'
    s.messages['play-pause']()
    check('Play/pause toggles pause mid-video',#s.commands==1 and s.commands[1][1]=='cycle' and s.commands[1][2]=='pause')
    s.props['eof-reached']=true; s.props.pause=true; s.messages['play-pause']()
    check('Play at end of video replays it',s.commands[2][1]=='seek' and s.commands[2][2]==0 and s.props.pause==false)

    s=fixture('history_menu.lua'); shared(s,a); s.props.path=a
    s:event('file-loaded'); s:fire(2)
    check('History uses shared metadata without yt-dlp',#s.jobs==1 and s.jobs[1].args[1]=='ffmpeg')

    s=fixture('history_menu.lua'); shared(s,b); s.props.path=a
    s:event('file-loaded'); s:fire(2)
    check('History rejects metadata for another video',#s.jobs==1 and s.jobs[1].args[1]=='yt-dlp')

    s=fixture('history_menu.lua'); s.props.path='D:/Media/sample.mp4'
    s.files[s.props.path]={is_file=true,size=1000,mtime=100}
    s:event('file-loaded'); s:fire(2)
    local job=s.jobs[1]; local target=job.args[#job.args]
    s.files[target]={is_file=true,size=300*168*4}
    job.cb(true,{status=0})
    s:event('file-loaded'); s:fire(2)
    check('Unchanged local file reuses valid thumbnail',#s.jobs==1)
    s.files[s.props.path].mtime=101
    s:event('file-loaded'); s:fire(2)
    check('Changed local source regenerates thumbnail',#s.jobs==2 and s.jobs[2].args[#s.jobs[2].args]~=target)
    s.jobs[2].cb(false,{status=1})
    s:event('file-loaded'); s:fire(2)
    check('Failed thumbnail job can be retried',#s.jobs==3)
end
local ok,err=xpcall(run,debug.traceback)
io=real_io
if ok then real.msg.info(('All %d regression checks passed'):format(passed))
else real.msg.error(err) end
real.commandv('quit',ok and 0 or 1)
