-- API/HTTP/JSON mocks only. Not a live Gamesense test.
load=loadstring
local controls={};ui={}
local function make(name,value,kind,callback)local it={name=name,value=value,kind=kind,callback=callback};controls[name]=it;return it end
function ui.new_label(_,__,name)return make(name,name,'label')end
function ui.new_listbox(_,__,name,items)local it=make(name,0,'list');it.items=items;return it end
function ui.new_button(_,__,name,fn)return make(name,nil,'button',fn)end
function ui.new_checkbox(_,__,name)return make(name,false,'checkbox')end
function ui.new_textbox(_,__,name)return make(name,'','textbox')end
function ui.get(ref)return ref.value end
function ui.set(ref,v)local changed=ref.value~=v;ref.value=v;if changed and ref.callback then ref.callback(ref)end end
function ui.set_visible(ref,v)ref.visible=v end
function ui.set_callback(ref,fn)ref.callback=fn end
function ui.update(ref,items,...)assert(type(items)=='table' and select('#',...)==0,'listbox update requires one table of strings');ref.items={};for i,v in ipairs(items)do assert(type(v)=='string');ref.items[i]=v end end
function ui.is_menu_open()return true end
function ui.menu_position()return 100,100 end
function ui.menu_size()return 650,500 end
local handlers,timers={},{}
client={set_event_callback=function(e,fn)handlers[e]=handlers[e] or {};table.insert(handlers[e],fn)end,unset_event_callback=function(e,fn)for i=#(handlers[e] or {}),1,-1 do if handlers[e][i]==fn then table.remove(handlers[e],i)end end end,delay_call=function(_,fn)table.insert(timers,fn)end}
local function fire(e,...)local copy={};for _,fn in ipairs(handlers[e] or {})do copy[#copy+1]=fn end;for _,fn in ipairs(copy)do fn(...)end end
local draw_count=0;renderer={line=function()draw_count=draw_count+1 end};local now=2;globals={realtime=function()return now end};client.unix_time=function()return 1000000+now end
local disk={};database={read=function(k)return disk[k]end,write=function(k,v)disk[k]=v end}
local fixtures,requests={},{}
local deferred=false;local pending={}
local http={get=function(url,opts,fn)
 assert(opts.require_ssl and opts.absolute_timeout==20)
 requests[#requests+1]=url
 local key=url:gsub('%?.*$','');local response=fixtures[key] or {success=false,status=404,body=''}
 if deferred then pending[#pending+1]={fn,response}else fn(response.success~=false,response)end
end}
local oldrequire=require;require=function(name)if name=='gamesense/http'then return http end;return oldrequire(name)end
local manifests={};json={parse=function(s)if not manifests[s]then error('invalid json')end;return manifests[s]end}
local f=assert(io.open(arg[1] or 'loader.lua'));local source=f:read('*a');f:close()
source=source:gsub("local REPOSITORY='valentinaxbianca1337%-cloud/loader'","local REPOSITORY=''",1)
local function boot(src)
 handlers={};controls={};pending={};timers={}
 assert(load(src..'\n_L={runtimes=runtimes,saved=saved,status=function()return status end,busy=function()return busy end,check=check_updates}'))();fire('paint_ui')
end
local function choose_row(index,delay)
 now=now+(delay or .1)
 ui.set(controls.loader,index)
 assert(ui.get(controls.loader)==0,'service row not restored: repeated selection would not trigger')
end
local function double_row(index)choose_row(index,.6);choose_row(index,.1)end
local function filled(index)return controls.loader.items[index+1]:find('◆',1,true)~=nil end
boot(source)
assert(not controls.Load and not controls.Unload and not controls['menu glow'] and not controls['GitHub repository (owner/repo)'],'unwanted widgets')
assert(controls.loader.kind=='list' and controls.loader.items[1]=='_' and #controls.loader.items==2)
assert(not source:find('mouse_position',1,true) and not source:find('renderer.rectangle',1,true),'floating panel present')
choose_row(1);assert(not _L.runtimes.menu_glow and not filled(1))
choose_row(1);assert(_L.runtimes.menu_glow.active and filled(1));fire('paint_ui');assert(draw_count>0)
choose_row(1);assert(_L.runtimes.menu_glow.active)
choose_row(1);assert(not _L.runtimes.menu_glow.active and not filled(1) and #handlers.paint_ui==1)
choose_row(1,.6);choose_row(1,.6);assert(not _L.runtimes.menu_glow.active,'slow clicks counted as double')
double_row(1);assert(_L.saved.autoload.menu_glow)
fire('shutdown');assert(#handlers.paint_ui==1)
boot(source);assert(_L.runtimes.menu_glow.active and filled(1),'startup selection lost');fire('shutdown')
-- Bind a repository in a test copy exactly as a future release would do.
local bound=source:gsub("local REPOSITORY=''", "local REPOSITORY='test-owner/test-repo'",1)
local root='https://raw.githubusercontent.com/test-owner/test-repo/main/'
local good='return {api_version=1,start=function(ctx)ctx:on("paint",function()_G.mock_ticks=(_G.mock_ticks or 0)+1 end);ctx:restore(function()_G.mock_restored=true end)end,stop=function()_G.mock_stops=(_G.mock_stops or 0)+1 end}'
local function update(version,code)
 manifests.current={schema=1,scripts={{id='example',name='example',version=version,path='scripts/example.lua'}}}
 fixtures[root..'manifest.json']={status=200,body='current'}
 fixtures[root..'scripts/example.lua']={status=200,body=code}
end
update('1',good);boot(bound)
assert(#controls.loader.items==3 and _L.saved.cache.example.version=='1')
assert(controls['Last Updated: not connected'].value:find('just now'))
double_row(2);assert(_L.runtimes.example.active and filled(2));fire('paint');assert(mock_ticks==1)
update('2',good..'\n-- version 2');_L.check()
assert(_L.runtimes.example.version=='1' and _L.saved.cache.example.version=='2','active code hot swapped')
assert(controls['Update Log: None'].value:find('Update ready'))
double_row(2);assert(not filled(2) and #handlers.paint==0 and mock_restored)
double_row(2);assert(_L.runtimes.example.version=='2' and filled(2))
double_row(2)
update('3','return {api_version=1,start=function(ctx)ctx:on("paint",function()end);error("broken start")end,stop=function()end}');_L.check()
double_row(2);assert(_L.runtimes.example.active and _L.runtimes.example.version=='2' and #handlers.paint==1,'working-version fallback failed')
double_row(2)
update('4','syntax error @');_L.check();assert(_L.saved.cache.example.version=='3','syntax-bad source cached')
fixtures[root..'manifest.json']={status=404,success=false};_L.check();assert(_L.saved.cache.example.good_version=='2','network failure discarded cache')
-- Different names cannot form one double click.
choose_row(1,.6);choose_row(2,.1);assert(not _L.runtimes.menu_glow and not _L.runtimes.example.active)
-- A module without any working fallback stays unfilled on error.
manifests.badstart={schema=1,scripts={{id='broken',name='broken',version='1',path='scripts/broken.lua'}}}
fixtures[root..'manifest.json']={status=200,body='badstart'}
fixtures[root..'scripts/broken.lua']={status=200,body='return {api_version=1,start=function(ctx)ctx:on("paint",function()end);error("bad module")end,stop=function()end}'}
_L.check();double_row(2);assert(not filled(2) and not _L.runtimes.broken.active and #handlers.paint==0)
-- Pending HTTP completion after shutdown must be ignored.
deferred=true;_L.check();assert(_L.busy());local c=_L.saved.cache
fire('shutdown');for _,p in ipairs(pending)do p[1](true,p[2])end
assert(_L.saved.cache==c)
print('PASS native listbox + service row, repeated same-name double clicks, real filled/unfilled state, no checkboxes/buttons/overlay, slow/different-name clicks, startup persistence, GitHub download/cache, update pending, fallback, errors and late HTTP shutdown')

-- Regression: populate all twelve real catalogue names with synthetic code.
deferred=false;disk={};requests={}
manifests.full={schema=1,scripts={
{id="aetheryx",name="Aetheryx",version="test-1",path="modules/aetheryx.lua",group="aa"},
{id="angelwings",name="Angelwings",version="test-1",path="modules/angelwings.lua",group="aa"},
{id="annesty",name="Annesty",version="test-1",path="modules/annesty.lua",group="aa"},
{id="bluhgang",name="Bluhgang",version="test-1",path="modules/bluhgang.lua",group="aa"},
{id="dormant",name="Dormant Aimbot",version="test-1",path="modules/dormant.lua",group="helper"},
{id="emberlash_v2",name="Emberlash v2",version="test-1",path="modules/emberlash_v2.lua",group="aa"},
{id="emberlash_legacy",name="Emberlash legacy",version="test-1",path="modules/emberlash_legacy.lua",group="aa"},
{id="evalate",name="Evalate",version="test-1",path="modules/evalate.lua",group="aa"},
{id="kamidere",name="Kamidere",version="test-1",path="modules/kamidere.lua",group="aa"},
{id="luasense",name="Luasense",version="test-1",path="modules/luasense.lua",group="aa"},
{id="resistance",name="Resistance",version="test-1",path="modules/resistance.lua",group="aa"},
{id="rinnegan",name="Rinnegan",version="test-1",path="modules/rinnegan.lua",group="aa"},
}}
fixtures[root.."manifest.json"]={status=200,body="full"}
for _,m in ipairs(manifests.full.scripts)do fixtures[root..m.path]={status=200,body=good}end
boot(bound)
assert(#controls.loader.items==13,"missing catalogue rows or Annesty not quarantined")
local row=3
for _,m in ipairs(manifests.full.scripts)do if m.id~="annesty" then assert(controls.loader.items[row]:find(m.name,1,true),"missing name: "..m.name);row=row+1 end end
assert(controls["Update Log: None"].value:find("11 module(s) updated",1,true))
fire("shutdown")
print("PASS 11 available names visible; Annesty excluded even from stale catalogue")

-- Cached autostart must be blocked before any old Annesty code executes.
disk.loader_v1_state={schema=1,repo='test-owner/test-repo',catalogue=manifests.full.scripts,cache={annesty={version='old',source='_G.annesty_ran=true;return {api_version=1,start=function()end,stop=function()end}'}},autoload={annesty=true}}
boot(bound)
assert(not annesty_ran and not _L.runtimes.annesty and not _L.saved.autoload.annesty and not _L.saved.cache.annesty,'Annesty cached autostart not blocked')
fire('shutdown')
print('PASS cached Annesty removed and autostart blocked before donor execution')
