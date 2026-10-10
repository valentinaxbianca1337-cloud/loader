-- loader 0.5.0 / Gamesense CS:GO
-- Trusted module manager, NOT a sandbox. Only use a repository you control.
-- Modules return { api_version=1, start=function(ctx), stop=function(ctx) }.
local LegacyBridge=(function()
-- Loader legacy bridge v1. Trusted-code lifecycle adaptation, NOT a security sandbox.
-- Does not sandbox FFI/native hooks or callbacks installed inside external libraries.
local Bridge={}
local function pack(...)return {n=select('#',...),...}end
local unpack_fn=unpack or table.unpack
local function clone(t)local r={};for k,v in pairs(t or {})do r[k]=v end;return r end
function Bridge.new(source,chunkname)
    local self={source=source,chunkname=chunkname,pool={},active=false}
    local host=_G
    local real_ui,real_client,real_renderer=ui,client,renderer
    local current_measure=nil
    local scope,shutdowns,event_map,ui_index,refs,snapshots,visible,cvar_proxies
    local function wrap(fn)
        return function(...)
            if not self.active or not scope or not scope.alive then return end
            local previous=current_measure;current_measure=false
            -- GameSense event consumers use at most the first returned value.
            local a,b,c,d,e=fn(...)
            current_measure=previous
            return a,b,c,d,e
        end
    end
    local ui_proxy=clone(real_ui)
    local client_proxy=clone(real_client)
    local renderer_proxy=clone(real_renderer)
    if type(real_renderer.measure_text)=='function'then
        renderer_proxy.measure_text=function(flags,...)
            local text=select(1,...)
            if current_measure~=nil and select('#',...)==1 and type(text)=='string' and type(flags)=='string' then
                if current_measure==false then current_measure={}end
                local key=flags..'\0'..text
                local hit=current_measure[key]
                if hit then return hit[1],hit[2]end
                local w,h=real_renderer.measure_text(flags,text)
                current_measure[key]={w,h}
                return w,h
            end
            return real_renderer.measure_text(flags,...)
        end
    end
    client_proxy.set_event_callback=function(event,fn)
        assert(type(fn)=='function','callback must be a function')
        event_map[event]=event_map[event] or {}
        if event_map[event][fn]then return end
        if event=='shutdown'then shutdowns[#shutdowns+1]=fn;event_map[event][fn]=true;return end
        event_map[event][fn]=scope:on(event,wrap(fn))
    end
    client_proxy.unset_event_callback=function(event,fn)
        local map=event_map[event];local wrapped=map and map[fn]
        if not wrapped then return end
        if event=='shutdown'then for i=#shutdowns,1,-1 do if shutdowns[i]==fn then table.remove(shutdowns,i)end end
        else real_client.unset_event_callback(event,wrapped)end
        map[fn]=nil
    end
    client_proxy.delay_call=function(delay,fn,...)
        local args=pack(...);local callback=wrap(fn)
        scope:defer(delay,function()return callback(unpack_fn(args,1,args.n))end)
    end
    for key,fn in pairs(real_ui)do
        if type(fn)=='function' and key:match('^new_')then
            local kind,native=key,fn
            ui_proxy[key]=function(...)
                local args=pack(...)
                ui_index=ui_index+1
                local signature=kind..'/'..tostring(args[1])..'/'..tostring(args[2])..'/'..tostring(args[3])
                local old=self.pool[ui_index]
                local callback
                for i=1,args.n do if type(args[i])=='function'then callback=wrap(args[i]);args[i]=callback end end
                local ref
                if old and old.signature==signature then
                    ref=old.ref
                    if callback then real_ui.set_callback(ref,callback)end
                    pcall(real_ui.set_visible,ref,true)
                else
                    ref=native(unpack_fn(args,1,args.n))
                    self.pool[ui_index]={signature=signature,ref=ref,kind=kind}
                end
                scope:track_ui(ref);refs[ref]=true
                return ref
            end
        end
    end
    ui_proxy.set_callback=function(ref,fn)return real_ui.set_callback(ref,wrap(fn))end
    ui_proxy.set=function(ref,...)
        if not refs[ref] and not snapshots[ref]then
            local old=pack(pcall(real_ui.get,ref))
            if old[1]then snapshots[ref]=true;scope:restore(function()pcall(real_ui.set,ref,unpack_fn(old,2,old.n))end)end
        end
        return real_ui.set(ref,...)
    end
    ui_proxy.set_visible=function(ref,state)
        if not refs[ref] and not visible[ref]then
            visible[ref]=true
            -- GS has no documented getter for native reference visibility.
            scope:restore(function()pcall(real_ui.set_visible,ref,true)end)
        end
        return real_ui.set_visible(ref,state)
    end
    local cvar_proxy=setmetatable({}, {__index=function(_,name)
        local obj=host.cvar and host.cvar[name]
        if not obj then return nil end
        if cvar_proxies[name]then return cvar_proxies[name]end
        local saved_methods={}
        local proxy=setmetatable({}, {__index=function(_,method)
            local native=obj[method]
            if type(native)~='function'then return native end
            return function(_, ...)
                if method:match('^set_') and not saved_methods[method]then
                    local suffix=method:gsub('^set_raw_',''):gsub('^set_','')
                    local get=obj['get_'..suffix]
                    if type(get)=='function'then
                        local ok,value=pcall(get,obj)
                        if ok then saved_methods[method]=true;scope:restore(function()pcall(native,obj,value)end)end
                    end
                end
                return native(obj,...)
            end
        end})
        cvar_proxies[name]=proxy
        return proxy
    end})
    function self:start(ctx)
        assert(type(setfenv)=='function','LuaJIT setfenv is required for legacy modules')
        scope=ctx;shutdowns={};event_map={};ui_index=0;refs={};snapshots={};visible={};cvar_proxies={}
        current_measure=nil;self.active=true
        local environment=clone(host)
        environment._G=environment;environment.client=client_proxy;environment.ui=ui_proxy
        environment.renderer=renderer_proxy;environment.cvar=cvar_proxy
        environment.math=clone(host.math);environment.table=clone(host.table);environment.string=clone(host.string)
        environment.package=clone(host.package)
        if host.package then environment.package.loaded=clone(host.package.loaded);environment.package.preload=clone(host.package.preload)end
        -- Leave require/ffi unchanged: library internals and native writes cannot be tracked here.
        local chunk,err=loadstring(self.source,self.chunkname)
        assert(chunk,err)
        setfenv(chunk,environment)
        self.environment=environment
        chunk()
        -- Release the root closure; registered handlers/UI callbacks own necessary state.
        chunk=nil
    end
    function self:stop()
        if not self.active then return end
        self.active=false;current_measure=nil
        for i=#shutdowns,1,-1 do pcall(shutdowns[i])end
        for _,item in ipairs(self.pool)do
            if item.kind~='new_string' and item.kind~='new_label' then pcall(real_ui.set_callback,item.ref,function()end)end
            pcall(real_ui.set_visible,item.ref,false)
        end
        self.environment=nil;shutdowns={};event_map={}
        -- ctx cleanup removes registered events and invokes recorded restorers.
    end
    return self
end
return Bridge

end)()
local TAB,BOX='LUA','B'
local KEY='loader_v1_state'
local REPOSITORY='valentinaxbianca1337-cloud/loader' -- Public owner/repo; bind once a repository is chosen.
local LIMIT,MAX_SOURCE,MAX_MANIFEST=20,12582912,65536
local unpack_fn=unpack or table.unpack
local http_ok,http=pcall(require,'gamesense/http')
local json_api=json
if not json_api then local ok,j=pcall(require,'json');if ok then json_api=j end end
local compiler=loadstring
local alive,epoch,busy=true,0,false
local saved=database.read(KEY)
if type(saved)~='table' or saved.schema~=1 then saved={schema=1,repo='',catalogue={},cache={},autoload={}}end
if type(saved.cache)~='table'then saved.cache={}end
if type(saved.catalogue)~='table'then saved.catalogue={}end
if type(saved.autoload)~='table'then saved.autoload={}end
local entries,by_id,runtimes={}, {}, {}
local startup_waiting={}
local refresh_ui,load_module,stop_module,check_updates
local syncing=false
local status='Ready'
local selected_index=0
saved.panel=nil
if REPOSITORY~='' and REPOSITORY~=saved.repo then saved.repo=REPOSITORY;saved.cache={};saved.catalogue={};saved.autoload={};saved.last_check=nil;saved.last_update=nil;saved.update_log=nil end
local tip=ui.new_label(TAB,BOX,'\aB7CD3CFFTIP: \aD8D8D8FFDouble click on script to load / unload it')
local list=ui.new_listbox(TAB,BOX,'loader',{'_'})
local updated_label=ui.new_label(TAB,BOX,'Last Updated: not connected')
local log_label=ui.new_label(TAB,BOX,'Update Log: None')
local function clean(s,n)return tostring(s or ''):gsub('[%z\1-\31\127]',' '):sub(1,n or 90)end
local function say(s)status=clean(s,110);if refresh_ui then refresh_ui()end end
local function persist()if alive then pcall(database.write,KEY,saved)end end
local function repo_name()
    local s=tostring(saved.repo or ''):match('^%s*(.-)%s*$')
    if s==''then return nil,'GitHub not connected' end
    if not s:match('^[%w_%-%.]+/[%w_%-%.]+$')then return nil,'Use owner/repo, not a URL' end
    return s
end
local function selected()return entries[selected_index+1]end
local function valid_meta(m)
    if type(m)~='table' or type(m.id)~='string' or not m.id:match('^[%w_%-]+$') or #m.id>48 or m.id=='menu_glow' then return false end
    if type(m.name)~='string' or #m.name<1 or #m.name>64 or m.name:find('[%z\1-\31\127]')then return false end
    if type(m.version)~='string' or #m.version<1 or #m.version>40 or m.version:find('[%z\1-\31\127]')then return false end
    if type(m.path)~='string' or #m.path>180 or not m.path:match('^[%w_/%-%.]+%.lua$') or m.path:find('..',1,true) or m.path:sub(1,1)=='/' then return false end
    return true
end
local builtin={id='menu_glow',name='menu glow',version='1.0.0',builtin=true}
local list_sync=false
local last_list_click=nil
local last_list_text=nil
local function refresh_list()
    local labels={'_'}
    for _,m in ipairs(entries)do
        local rt=runtimes[m.id]
        local marker=rt and rt.active and '◆' or '◇'
        labels[#labels+1]='\a939393FF'..marker..' \aB7CD3CFF'..m.name
    end
    local fingerprint=table.concat(labels,'\0')
    list_sync=true
    if last_list_text~=fingerprint then ui.update(list,unpack_fn(labels));last_list_text=fingerprint end
    -- The service row makes two clicks on the same name observable as two changes.
    ui.set(list,0)
    list_sync=false
end
ui.set_callback(list,function()
    if list_sync or syncing or not alive then return end
    local value=tonumber(ui.get(list)) or 0
    if value<=0 then return end
    local m=entries[value];if not m then refresh_list();return end
    selected_index=value-1
    list_sync=true;ui.set(list,0);list_sync=false
    local now=globals.realtime()
    if last_list_click and last_list_click.id==m.id and now-last_list_click.time>=0 and now-last_list_click.time<=.35 then
        last_list_click=nil
        local rt=runtimes[m.id]
        if rt and rt.active then
            startup_waiting[m.id]=nil;stop_module();saved.autoload[m.id]=false
        else
            load_module(m.id)
            rt=runtimes[m.id];saved.autoload[m.id]=rt and rt.active or false
        end
        persist()
    else last_list_click={id=m.id,time=now}end
    refresh_ui()
end)

local function rebuild()
    local keep=selected();keep=keep and keep.id
    entries={builtin};by_id={menu_glow=builtin}
    for _,m in ipairs(saved.catalogue)do
        if #entries<=LIMIT and valid_meta(m) and not by_id[m.id]then entries[#entries+1]=m;by_id[m.id]=m end
    end
    local labels,index={},0
    for i,m in ipairs(entries)do labels[i]=m.name;if m.id==keep then index=i-1 end end
    selected_index=index;last_list_click=nil
    refresh_ui()
end
local function wall_time()
    if client.unix_time then return client.unix_time()end
    if os and os.time then return os.time()end
    return 0
end
refresh_ui=function()
    refresh_list()
    local stamp=tonumber(saved.last_update)
    local age=stamp and math.max(0,wall_time()-stamp) or nil
    local text='not connected'
    if age then
        if age<60 then text='just now'
        elseif age<3600 then text=tostring(math.floor(age/60))..' min ago'
        elseif age<86400 then text=tostring(math.floor(age/3600))..' hours ago'
        else text=tostring(math.floor(age/86400))..' days ago'end
    elseif saved.repo~=''then text='not downloaded'end
    ui.set(updated_label,'Last Updated: '..text)
    local m=selected()
    local c=m and saved.cache[m.id]
    local rt=m and runtimes[m.id]
    local log=saved.update_log or 'None'
    if not status:find('^Check complete:') and (status:find('failed',1,true) or status:find('unavailable',1,true) or status:find('Invalid',1,true) or status:find('stopped',1,true)) then log=status
    elseif rt and rt.active and c and c.version~=rt.version then log='Update ready; reload '..m.name end
    ui.set(log_label,'Update Log: '..clean(log,95))
end
local function cleanup(scope)
    if not scope then return end
    scope.alive=false
    for _,e in ipairs(scope.callbacks)do pcall(client.unset_event_callback,e[1],e[2])end
    for _,ref in ipairs(scope.controls)do pcall(ui.set_visible,ref,false)end
    for i=#scope.restores,1,-1 do pcall(scope.restores[i])end
    scope.callbacks={};scope.controls={};scope.restores={}
end
local function context(id)
    local scope={alive=true,callbacks={},controls={},restores={}}
    function scope:on(event,fn)
        assert(self.alive and type(event)=='string' and type(fn)=='function','Invalid event registration')
        local wrapped=function(...)
            if not alive or not self.alive then return end
            local ok,err,a,b,c,d=pcall(fn,...)
            if not ok then
                local rt=runtimes[id];if rt then rt.active=false;rt.error=clean(err);pcall(rt.module.stop,self)end
                cleanup(self);say('Module stopped: '..id..' | '..clean(err,65))
            else return err,a,b,c,d end
        end
        client.set_event_callback(event,wrapped)
        self.callbacks[#self.callbacks+1]={event,wrapped}
        return wrapped
    end
    function scope:track_ui(ref)
        assert(self.alive,'Inactive module');self.controls[#self.controls+1]=ref;return ref
    end
    function scope:restore(fn)assert(self.alive and type(fn)=='function');self.restores[#self.restores+1]=fn end
    function scope:defer(seconds,fn)
        assert(self.alive and type(fn)=='function')
        client.delay_call(seconds,function()
            if alive and self.alive then
                local ok,err=pcall(fn)
                if not ok then local rt=runtimes[id];if rt then rt.active=false;pcall(rt.module.stop,self)end;cleanup(self);say('Module timer failed: '..clean(err,70))end
            end
        end)
    end
    function scope:legacy(source,chunkname)return LegacyBridge.new(source,chunkname)end
    return scope
end
local function builtin_module()
    return {api_version=1,start=function(ctx)
        ctx:on('paint_ui',function()
            if not ui.is_menu_open()then return end
            local x,y=ui.menu_position();local w=ui.menu_size()
            if type(x)~='number' or type(w)~='number' or w<30 then return end
            local t=globals.realtime();local head=(t/6%1)*(w+120)-60
            for i=1,28 do
                local a=math.max(0,math.min(w,head-100+(i-1)*4))
                local b=math.max(0,math.min(w,head-100+i*4))
                if b>a then renderer.line(x+a,y-2,x+b,y-2,202,190,241,math.floor(220*(i/28)^2))end
            end
        end)
    end,stop=function()end}
end
local function instantiate(source,id)
    if not compiler then return nil,'loadstring unavailable in this Gamesense runtime'end
    local chunk,err=compiler(source,'@loader/'..id)
    if not chunk then return nil,clean(err,90)end
    local ok,module=pcall(chunk)
    if not ok then return nil,clean(module,90)end
    if type(module)~='table' or module.api_version~=1 or type(module.start)~='function' or type(module.stop)~='function' then return nil,'Module must return API v1 with start(ctx) and stop(ctx)'end
    return module
end
local function stop_id(id,quiet)
    local rt=runtimes[id]
    if not rt or not rt.active then return end
    rt.active=false
    local ok,err=pcall(rt.module.stop,rt.scope)
    cleanup(rt.scope)
    if not quiet then say(ok and ('Unloaded: '..id) or ('Unloaded with stop error: '..clean(err,70)))end
end
stop_module=function()local m=selected();if m then startup_waiting[m.id]=nil;stop_id(m.id,false);refresh_ui()end end
local function start_source(m,source,version)
    local rt=runtimes[m.id]
    local module,err
    if rt and rt.source==source and rt.module then module=rt.module
    elseif m.builtin then module=builtin_module()
    else module,err=instantiate(source,m.id)end
    if not module then return false,err end
    local scope=context(m.id)
    rt={module=module,source=source,version=version,scope=scope,active=true};runtimes[m.id]=rt
    local ok,start_error=pcall(module.start,scope)
    if not ok then rt.active=false;pcall(module.stop,scope);cleanup(scope);return false,clean(start_error,90)end
    return true
end
load_module=function(id)
    local m=id and by_id[id] or selected();if not m then return end
    if runtimes[m.id] and runtimes[m.id].active then say('Already running. Unload before applying an update.');return end
    if m.group=='aa' then
        for other_id,other_rt in pairs(runtimes)do
            if other_id~=m.id and other_rt.active and by_id[other_id] and by_id[other_id].group=='aa' then
                say('Unload '..by_id[other_id].name..' before loading another AA script');return
            end
        end
    end
    local c=saved.cache[m.id]
    if not m.builtin and (not c or type(c.source)~='string')then say('Not downloaded. Connect GitHub and check updates.');return end
    local source=m.builtin and '@builtin/menu_glow' or c.source
    local version=m.builtin and m.version or c.version
    local ok,err=start_source(m,source,version)
    if not ok and c and type(c.good_source)=='string' and c.good_source~=source then
        ok,err=start_source(m,c.good_source,c.good_version)
        if ok then say('Previous working version loaded: '..m.name);return end
    end
    if not ok then say('Load failed: '..clean(err,90));return end
    if c then c.good_source=nil;c.good_version=version;persist()end
    say('Loaded: '..m.name)
end
local function request(url,token,fn)
    if not http_ok or type(http)~='table' or type(http.get)~='function'then fn(false,nil,'gamesense/http is not installed');return end
    local ok,err=pcall(http.get,url,{network_timeout=10,absolute_timeout=20,require_ssl=true},function(success,response)
        if not alive or token~=epoch then return end
        fn(success,response)
    end)
    if not ok and alive and token==epoch then fn(false,nil,clean(err,90))end
end
check_updates=function()
    if busy then say('Update check is already running');return end
    local repo,err=repo_name();if not repo then say(err);return end
    if not json_api or type(json_api.parse)~='function'then say('JSON parser unavailable');return end
    busy=true;epoch=epoch+1;local token=epoch
    local root='https://raw.githubusercontent.com/'..repo..'/main/'
    say('Checking GitHub...')
    request(root..'manifest.json?loader='..tostring(math.floor(globals.realtime()*1000)),token,function(success,response,why)
        if not success or not response or response.status~=200 or type(response.body)~='string' or #response.body>MAX_MANIFEST then busy=false;say(why or 'GitHub unavailable; local cache retained');return end
        local ok,data=pcall(json_api.parse,response.body)
        if not ok or type(data)~='table' or data.schema~=1 or type(data.scripts)~='table' or #data.scripts>LIMIT then busy=false;say('Invalid manifest; local cache retained');return end
        local catalogue,seen={},{}
        for _,m in ipairs(data.scripts)do
            if not valid_meta(m) or seen[m.id]then busy=false;say('Invalid or duplicate module in manifest');return end
            seen[m.id]=true;catalogue[#catalogue+1]={id=m.id,name=m.name,version=m.version,path=m.path,group=m.group,legacy=m.legacy}
        end
        saved.catalogue=catalogue;saved.last_check=wall_time();rebuild()
        local index,updated,failed=0,0,0
        local function next_download()
            if not alive or token~=epoch then return end
            index=index+1;local m=catalogue[index]
            if not m then busy=false;if updated>0 then saved.last_update=wall_time()end;saved.update_log=failed>0 and (tostring(failed)..' download(s) failed') or updated>0 and (tostring(updated)..' module(s) updated') or 'None';persist();say('Check complete: '..updated..' updated, '..failed..' failed');return end
            local c=saved.cache[m.id]
            if c and c.version==m.version and type(c.source)=='string'then next_download();return end
            request(root..m.path..'?loader='..tostring(math.floor(globals.realtime()*1000)),token,function(got,res)
                if got and res and res.status==200 and type(res.body)=='string' and #res.body<=MAX_SOURCE and compiler then
                    local chunk=compiler(res.body,'@loader/check/'..m.id)
                    if chunk then
                        saved.cache[m.id]={source=res.body,version=m.version,good_source=c and (c.good_source or (c.good_version==c.version and c.source)),good_version=c and c.good_version}
                        updated=updated+1
                        if startup_waiting[m.id] and saved.autoload[m.id] then startup_waiting[m.id]=nil;load_module(m.id)end
                    else failed=failed+1 end
                else failed=failed+1 end
                next_download()
            end)
        end
        next_download()
    end)
end
client.set_event_callback('shutdown',function()
    epoch=epoch+1;busy=false
    for id in pairs(runtimes)do stop_id(id,true)end
    persist();alive=false
end)
status=saved.repo~='' and 'Local cache ready' or 'GitHub not connected | local demo available'
rebuild()
for id,wanted in pairs(saved.autoload)do
    if wanted and by_id[id]then
        if by_id[id].builtin or saved.cache[id] then load_module(id)else startup_waiting[id]=true end
    end
end
local next_check=0
client.set_event_callback('paint_ui',function()
    if alive and ui.is_menu_open() and saved.repo~='' and not busy and globals.realtime()>=next_check then
        next_check=globals.realtime()+300;check_updates()
    end
end)
-- Updates are checked at most once per five minutes while the menu is open.
