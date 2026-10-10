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
