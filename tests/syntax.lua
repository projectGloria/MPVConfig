-- Compile sources without executing playback scripts or reading runtime state.
local mp=require 'mp'
local utils=require 'mp.utils'
local count=0
local function walk(path)
    for _,name in ipairs(utils.readdir(path,'files') or {}) do
        if name:match('%.lua$') then
            assert(loadfile(utils.join_path(path,name)))
            count=count+1
        end
    end
    for _,name in ipairs(utils.readdir(path,'dirs') or {}) do walk(utils.join_path(path,name)) end
end
local ok,err=xpcall(function()
    walk('portable_config/scripts')
    walk('portable_config/script-modules')
    walk('extras/sponsorblock/scripts')
end,debug.traceback)
if ok then mp.msg.info(('Syntax OK: %d Lua files'):format(count)) else mp.msg.error(err) end
mp.commandv('quit',ok and 0 or 1)
