-- Verify package download defaults/overrides with all subprocesses mocked.
local real=require 'mp'
local utils=require 'mp.utils'
local function run(options,expected_home,expected_temp)
    local binding,args
    local m={}
    m.get_property=function() return 'https://example.invalid/video' end
    m.command_native=function() return 'not-installed.exe' end
    m.command_native_async=function(command) args=command.args end
    m.osd_message=function() end
    m.add_key_binding=function(_,_,cb) binding=cb end
    package.loaded.mp=m
    package.loaded['mp.utils']={join_path=utils.join_path,file_info=function() return nil end}
    package.loaded['mp.options']={read_options=function(o) for k,v in pairs(options) do o[k]=v end end}
    local chunk=assert(loadfile('portable_config/scripts/ytdlp_download.lua'))
    setfenv(chunk,setmetatable({os={getenv=function(name) return name=='USERPROFILE' and 'C:/Users/Example' or nil end}},{__index=_G}))
    chunk(); binding()
    assert(args[3]=='home:'..expected_home,'wrong completed download directory')
    assert(args[5]=='temp:'..expected_temp,'wrong temporary directory')
end
local ok,err=xpcall(function()
    local home=utils.join_path('C:/Users/Example','Downloads/mpv')
    run({},home,utils.join_path(home,'_incomplete'))
    run({directory='E:/Media'},'E:/Media',utils.join_path('E:/Media','_incomplete'))
    run({directory='E:/Media',temp_directory='F:/Partial'},'E:/Media','F:/Partial')
end,debug.traceback)
if ok then real.msg.info('PASS: default, custom and separate temporary download paths') else real.msg.error(err) end
real.commandv('quit',ok and 0 or 1)
