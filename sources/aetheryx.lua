-- v16: user's manual arrows + independent outer desync pair
-- Aetheryx v1.4.1: no descriptions/Step Builder; peek telemetry transport v2.1.
local aetheryx_combo_core = (function()
-- Pure logic shared by the integrated helper and AB memory.
local M = {}
local function clamp(n,a,b) return math.max(a,math.min(b,tonumber(n) or a)) end
function M.reason(reason)
    reason=tostring(reason or '?'):lower()
    if reason=='spread' then return 'Spread' end
    if reason=='prediction error' or reason=='prediction' then return 'Prediction' end
    if reason=='unregistered' then return 'Unregistered' end
    if reason=='resolver' then return 'Resolver' end
    if reason=='?' or reason=='unknown' then return 'Unknown' end
    return 'Other'
end
function M.lethal(hp,damage,margin)
    hp,damage=tonumber(hp),tonumber(damage)
    return hp~=nil and damage~=nil and damage>0
        and damage>=hp+(tonumber(margin) or 0)
end
function M.new_memory()
    local self={records={}}
    function self:clear(id) if id then self.records[id]=nil else self.records={} end end
    function self:get(id,now,decay)
        local r=self.records[id]
        if r and now-r.time>=decay then self.records[id]=nil;r=nil end
        return r
    end
    function self:shot(id,token,now,decay,reason,body,yaw,delay,duration)
        local r=self:get(id,now,decay)
        if r and r.seen[token] then
            if r.token==token and reason=='player hurt' then r.reason=reason end
            return r,false
        end
        local seen=r and r.seen or {}
        seen[token]=now
        local total=0
        for k,t in pairs(seen) do
            if now-t>decay then seen[k]=nil else total=total+1 end
        end
        if total>32 then
            local oldest,stamp=nil,math.huge
            for k,t in pairs(seen) do if t<stamp then oldest,stamp=k,t end end
            seen[oldest]=nil
        end
        r={seen=seen,phase=r and r.phase%3+1 or 1,token=token,time=now,
            reason=reason,body=body,yaw=yaw,ready=now+delay,
            expires=duration==math.huge and math.huge or now+duration,pending=true}
        self.records[id]=r
        return r,true
    end
    return self
end
return M
end)()
local ffi = require 'ffi'
local vector = require 'vector'
local base64 = require 'gamesense/base64'
local clipboard = require 'gamesense/clipboard'
-- crash-safe: direct gamesense/entity animstate/overlay access disabled
local csgo_weapons = require 'gamesense/csgo_weapons'

-- Evalate-style feedback sound for script and config actions.
local function aetheryx_evalate_sound(volume)
local playvol = cvar and cvar.playvol
if playvol == nil then return end
pcall(function()
playvol:invoke_callback('training\\scoreregular', tostring(volume or 0.3))
end)
end
client.delay_call(0.15, aetheryx_evalate_sound, 0.3)
local function DUMMY(...)
return ...
end
local legacy_runtime = rawget(_G, '__aetheryx_runtime')
if type(legacy_runtime) == 'table' and type(legacy_runtime.events) == 'table' then
for _, event in pairs(legacy_runtime.events) do
event.list = { }
event.items = { }
end
end
rawset(_G, '__aetheryx_runtime', {
events = { },
generation = (
type(legacy_runtime) == 'table'
and tonumber(legacy_runtime.generation)
or 0
) or 0,
dispatch = function() end,
set = function() end,
unset = function() end,
delay = function() end
})

local runtime_key = '__aetheryx_runtime_v6_icon_clean'
local previous_runtime = rawget(_G, runtime_key)
local __aetheryx_runtime
if type(previous_runtime) == 'table' and type(previous_runtime.events) == 'table' then
for _, event in pairs(previous_runtime.events) do
event.list = { }
event.items = { }
end
previous_runtime.generation = (previous_runtime.generation or 0) + 1
__aetheryx_runtime = previous_runtime
else
__aetheryx_runtime = { events = { }, generation = 1 }
rawset(_G, runtime_key, __aetheryx_runtime)
end
do
local function now()
return globals.realtime()
end
local function report(event_name, err)
client.error_log(string.format(
'[aetheryx] %s callback error: %s',
tostring(event_name), tostring(err)
))
end
function __aetheryx_runtime.dispatch(event_name, ...)
local event = __aetheryx_runtime.events[event_name]
if event == nil then
return
end
local time = now()
local list = event.list
for i = 1, #list do
local item = list[i]
if item.active and time >= item.retry_at then
local ok, err = pcall(item.callback, ...)
if ok then
item.retry_at = 0
else
item.retry_at = time + 1
if time >= item.report_at then
item.report_at = time + 5
report(event_name, err)
end
end
end
end
end
function __aetheryx_runtime.set(event_name, callback)
if type(event_name) ~= 'string' or type(callback) ~= 'function' then
return
end
local event = __aetheryx_runtime.events[event_name]
if event == nil then
event = {
list = { },
items = { },
registered = false
}
__aetheryx_runtime.events[event_name] = event
end
local item = event.items[callback]
if item == nil then
item = {
callback = callback,
active = true,
retry_at = 0,
report_at = 0
}
event.items[callback] = item
event.list[#event.list + 1] = item
else
item.active = true
item.retry_at = 0
end
if not event.registered then
event.registered = true
client.set_event_callback(event_name, function(...)
__aetheryx_runtime.dispatch(event_name, ...)
end)
end
end
function __aetheryx_runtime.unset(event_name, callback)
local event = __aetheryx_runtime.events[event_name]
if event == nil then
return
end
local item = event.items[callback]
if item ~= nil then
item.active = false
end
end
end
function __aetheryx_runtime.delay(delay, callback, ...)
local args = { ... }
local count = select('#', ...)
client.delay_call(delay, function()
local ok, err = pcall(callback, unpack(args, 1, count))
if not ok then
report('delay_call', err)
end
end)
end
local drag_system = { } do
local key = '##AETHERYX_DRAG_POSITIONS'
local positions = database.read(key) or { }
local active = { }
local start_positions = { }
local drag_now = nil
local right_click_down = false

local function inside(mx, my, x, y, w, h)
return mx >= x and mx <= x + w and my >= y and my <= y + h
end

function drag_system.update(id, x, y, w, h, opts)
opts = opts or { }

local saved = positions[id]
if saved ~= nil then
x, y = saved.x or x, saved.y or y
end

local mx, my = ui.mouse_position()
local menu_x, menu_y = ui.menu_position()
local menu_w, menu_h = ui.menu_size()

local in_menu =
mx >= menu_x and mx <= menu_x + menu_w
and my >= menu_y and my <= menu_y + menu_h

local hovered = inside(mx, my, x, y, w, h)
local hover_distance = opts.hover_distance or 30
local near =
mx >= x - hover_distance and mx <= x + w + hover_distance
and my >= y - hover_distance and my <= y + h + hover_distance

local dragging = active[id] == true

-- source source: RMB resets a draggable when hovered outside the menu.
local right_now = client.key_state(0x02)
if right_now and not right_click_down
and hovered and not in_menu and ui.is_menu_open() then
positions[id] = nil
x, y = opts.default_x or x, opts.default_y or y
database.write(key, positions)
end
right_click_down = right_now

if in_menu then
active[id] = nil
end

if drag_now ~= nil and not client.key_state(0x01) then
drag_now = nil
end

-- source source: drag only while menu is open, hovered, and mouse isn't
-- over the menu itself.
if ui.is_menu_open()
and hovered
and not in_menu
and client.key_state(0x01)
and not dragging
and drag_now == nil then
active[id] = true
drag_now = id
start_positions[id] = {
mouse_x = mx,
mouse_y = my,
x = x,
y = y
}
dragging = true
end

if dragging then
if client.key_state(0x01) then
local start_pos = start_positions[id]
if start_pos ~= nil then
local new_x = start_pos.x + (mx - start_pos.mouse_x)
local new_y = start_pos.y + (my - start_pos.mouse_y)
local sw, sh = client.screen_size()

new_x = math.max(opts.min_x or 0, math.min(opts.max_x or math.max(0, sw - w), new_x))
new_y = math.max(opts.min_y or 0, math.min(opts.max_y or math.max(0, sh - h), new_y))

positions[id] = { x = new_x, y = new_y }
x, y = new_x, new_y
end
else
if drag_now == id then drag_now = nil end
active[id] = nil
start_positions[id] = nil
database.write(key, positions)
dragging = false
end
end

-- Literal source drag feedback: faint fill + 1px white border.
-- The darkened world in the reference screenshot is the GameSense menu layer,
-- not a fullscreen rectangle drawn by source.
if ui.is_menu_open() then
local should_draw
if drag_now ~= nil then
should_draw = drag_now == id
else
should_draw = hovered or near
end

if should_draw then
local alpha = dragging and 220 or 120
renderer.rectangle(x, y, w, h, 255, 255, 255, 12)
renderer.rectangle(x, y - 1, w + 1, 1, 255, 255, 255, alpha)
renderer.rectangle(x, y + h + 1, w + 1, 1, 255, 255, 255, alpha)
renderer.rectangle(x - 1, y, 1, h + 1, 255, 255, 255, alpha)
renderer.rectangle(x + w + 1, y, 1, h + 1, 255, 255, 255, alpha)
end
end

return math.floor(x), math.floor(y)
end

function drag_system.reset(id)
positions[id] = nil
active[id] = nil
start_positions[id] = nil
if drag_now == id then drag_now = nil end
database.write(key, positions)
end

function drag_system.is_dragging(id)
return active[id] == true
end

function drag_system.is_any_dragging()
return drag_now ~= nil
end
end
local visual_colors = { menu_color=nil } do
local ok,item=pcall(ui.reference,'Misc','Settings','Menu color')
if ok then visual_colors.menu_color=item end
local function menu_accent()
if visual_colors.menu_color~=nil then
local ok_get,r,g,b,a=pcall(ui.get,visual_colors.menu_color)
if ok_get and type(r)=='number' then return {r=r,g=g,b=b,a=type(a)=='number' and a or 255} end
end
return {r=235,g=235,b=235,a=255}
end
function visual_colors.get(window_name,position)
return menu_accent()
end
function visual_colors.unpack(window_name,position,alpha_multiplier)
local c=menu_accent(); alpha_multiplier=tonumber(alpha_multiplier) or 1
return c.r,c.g,c.b,math.max(0,math.min(255,math.floor(c.a*alpha_multiplier+0.5)))
end
end
local aa_runtime_state = { manual_direction = nil, aa_owner = nil, aa_state = nil, desync_offset = 0 }
local function contains(list, value)
for i = 1, #list do
if list[i] == value then
return i
end
end
return nil
end
local script = { } do
script.name = 'aetheryx'
local function loader_username()
local keys = {
'AETHERYX_LOADER_USERNAME', 'LOADER_USERNAME', 'loader_username',
'loader_user', 'username', 'user_name'
}
for i = 1, #keys do
local value = rawget(_G, keys[i])
if type(value) == 'string' and value ~= '' then return value end
if type(value) == 'function' then
local ok, result = pcall(value)
if ok and type(result) == 'string' and result ~= '' then return result end
end
end
local tables = {'loader', 'Loader', 'account', 'user'}
for i = 1, #tables do
local value = rawget(_G, tables[i])
if type(value) == 'table' then
for _, field in ipairs({'username', 'name', 'login', 'user'}) do
local result = value[field]
if type(result) == 'string' and result ~= '' then return result end
if type(result) == 'function' then
local ok, text = pcall(result, value)
if ok and type(text) == 'string' and text ~= '' then return text end
end
end
end
end
local stored = database.read('aetheryx.loader.username')
if type(stored) == 'string' and stored ~= '' then return stored end
local ok, api = pcall(panorama.open)
if ok and type(api) == 'table' and api.MyPersonaAPI ~= nil
and type(api.MyPersonaAPI.GetName) == 'function' then
local ok_name, name = pcall(api.MyPersonaAPI.GetName)
if ok_name and type(name) == 'string' and name ~= '' then return name end
end
return 'loader'
end
script.user = loader_username()
end

-- source-style fallback watermark: always enabled by default.
-- Layout intentionally mirrors source's simple left-side watermark: brand
-- in the current GameSense menu accent, followed by a white account suffix.
do
local watermark_alpha = 0
local watermark_brand = 'Aetheryx renewed'
local watermark_suffix = ' / admin'

local function render_default_watermark()
local _, sh = client.screen_size()
local ft = globals.frametime() or 0.016
local step = math.min(1, math.max(0.05, ft * 12))
watermark_alpha = watermark_alpha + (255 - watermark_alpha) * step
local a = math.max(0, math.min(255, math.floor(watermark_alpha + 0.5)))
if a <= 0 then return end

local r, g, b = visual_colors.unpack(nil, nil, 1)
local x = 5
local _, text_h = renderer.measure_text('b', watermark_brand .. watermark_suffix)
local y = math.floor((sh * 0.5) - ((text_h or 0) * 0.5))
local brand_w = select(1, renderer.measure_text('b', watermark_brand)) or 0

renderer.text(x, y, r, g, b, a, 'b', 0, watermark_brand)
renderer.text(x + brand_w, y, 255, 255, 255, a, 'b', 0, watermark_suffix)
end

-- legacy left-side watermark disabled; replaced by Aetheryx Glass HUD below
end

local color = { } do
color = ffi.typeof [[
        struct {
            unsigned char r;
            unsigned char g;
            unsigned char b;
            unsigned char a;
        }
    ]]
local M = { } do
M.__index = M
function M:__tostring()
return string.format(
'%i, %i, %i, %i',
self:unpack()
)
end
function M.lerp(a, b, t)
return color(
a.r + t * (b.r - a.r),
a.g + t * (b.g - a.g),
a.b + t * (b.b - a.b),
a.a + t * (b.a - a.a)
)
end
function M:unpack()
return self.r, self.g, self.b, self.a
end
function M:clone()
return color(self:unpack())
end
function M:to_hex()
return string.format(
'%02x%02x%02x%02x',
self:unpack()
)
end
function M:hsv(h, s, v)
local r, g, b
h = (h % 1.0) * 360
s = math.max(0, math.min(s, 1))
v = math.max(0, math.min(v, 1))
local c = v * s
local x = c * (1 - math.abs((h / 60) % 2 - 1))
local m = v - c
if h < 60 then
r, g, b = c, x, 0
elseif h < 120 then
r, g, b = x, c, 0
elseif h < 180 then
r, g, b = 0, c, x
elseif h < 240 then
r, g, b = 0, x, c
elseif h < 300 then
r, g, b = x, 0, c
else
r, g, b = c, 0, x
end
self.r = (r + m) * 255
self.g = (g + m) * 255
self.b = (b + m) * 255
self.a = 255
return self
end
end
ffi.metatype(color, M)
end
local motion do
motion = { }
local function linear(t, b, c, d)
return c * t / d + b
end
local function get_deltatime()
return globals.frametime()
end
local function solve(easing_fn, prev, new, clock, duration)
if clock <= 0 then return new end
if clock >= duration then return new end
prev = easing_fn(clock, prev, new - prev, duration)
if type(prev) == 'number' then
if math.abs(new - prev) < 0.001 then
return new
end
local remainder = prev % 1.0
if remainder < 0.001 then
return math.floor(prev)
end
if remainder > 0.999 then
return math.ceil(prev)
end
end
return prev
end
function motion.interp(a, b, t, easing_fn)
easing_fn = easing_fn or linear
if type(b) == 'boolean' then
b = b and 1 or 0
end
return solve(easing_fn, a, b, get_deltatime(), t)
end
end
local utils = { } do
local GetTimescale = vtable_bind('engine.dll', 'VEngineClient014', 91, 'float(__thiscall*)(void*)')
function utils.lerp(a, b, t)
return a + (b - a) * t
end
function utils.from_hex(hex)
hex = string.gsub(hex, '#', '')
local r = tonumber(string.sub(hex, 1, 2), 16)
local g = tonumber(string.sub(hex, 3, 4), 16)
local b = tonumber(string.sub(hex, 5, 6), 16)
local a = tonumber(string.sub(hex, 7, 8), 16)
return r, g, b, a or 255
end
function utils.to_hex(r, g, b, a)
return string.format('%02x%02x%02x%02x', r, g, b, a)
end
function utils.extrapolate(pos, vel, ticks)
return pos + vel * (ticks * globals.tickinterval())
end
function utils.normalize(x, min, max)
local d = max - min
while x < min do
x = x + d
end
while x > max do
x = x - d
end
return x
end
function utils.trim(str)
if type(str) ~= 'string' then
return str
end
return str:match('^%s*(.-)%s*$')
end
function utils.clamp(x, min, max)
return math.max(min, math.min(x, max))
end
function utils.event_callback(event_name, callback, value)
local fn = value == false
and __aetheryx_runtime.unset
or __aetheryx_runtime.set
fn(event_name, callback)
end
function utils.get_eye_position(ent)
local origin_x, origin_y, origin_z = entity.get_origin(ent)
local offset_x, offset_y, offset_z = entity.get_prop(ent, 'm_vecViewOffset')
if origin_x == nil or offset_x == nil then
return nil
end
local eye_pos_x = origin_x + offset_x
local eye_pos_y = origin_y + offset_y
local eye_pos_z = origin_z + offset_z
return eye_pos_x, eye_pos_y, eye_pos_z
end
function utils.get_player_weapons(ent)
local weapons = { }
for i = 0, 63 do
local weapon = entity.get_prop(
ent, 'm_hMyWeapons', i
)
if weapon == nil then
goto continue
end
table.insert(weapons, weapon)
::continue::
end
return weapons
end
function utils.random_int(min, max)
if min > max then
min, max = max, min
end
return client.random_int(min, max)
end
function utils.random_float(min, max)
if min > max then
min, max = max, min
end
return client.random_float(min, max)
end
function utils.get_clock()
return globals.frametime() / GetTimescale()
end
function utils.merge(...)
local str = ''
for i = 1, select('#', ...) do
str = str .. select(i, ...)
end
return str
end
function utils.normalize_angle(angle)
while angle > 180 do
angle = angle - 360
end
while angle < -180 do
angle = angle + 360
end
return angle
end
end
local wrappers = { } do
function wrappers.linear(t, b, c, d)
return c * t / d + b
end
function wrappers.solve(easing_fn, prev, new, clock, duration)
if clock <= 0 then
return new
end
if clock >= duration then
return new
end
prev = easing_fn(clock, prev, new - prev, duration)
if type(prev) == "number" then
if math.abs(new - prev) < 0.001 then
return new
end
local fmod = prev % 1
if fmod < 0.001 then
return math.floor(prev)
end
if fmod > 0.999 then
return math.ceil(prev)
end
end
return prev
end
function wrappers.interp(a, b, t, easing_fn)
easing_fn = easing_fn or wrappers.linear
if type(b) == "boolean" then
b = b and 1 or 0
end
return wrappers.solve(easing_fn, a, b, utils.get_clock(), t)
end
function wrappers.normalize_yaw(yaw)
return (yaw + 180) % -360 + 180
end
end
local helper_motion = { } do
function helper_motion.factor(speed)
local dt = math.max(0, math.min(globals.frametime(), 0.1))
return 1 - math.exp(-math.max(0, speed or 0) * dt)
end
function helper_motion.ease_out_cubic(t)
t = math.max(0, math.min(1, t or 0))
return 1 - (1 - t) ^ 3
end
function helper_motion.ease_in_out_sine(t)
t = math.max(0, math.min(1, t or 0))
return -(math.cos(math.pi * t) - 1) * 0.5
end
function helper_motion.approach(current, target, speed)
local factor = helper_motion.ease_out_cubic(helper_motion.factor(speed))
return current + (target - current) * factor
end
end
local ilocalize = { } do
local ConvertAnsiToUnicode = vtable_bind(
'localize.dll', 'Localize_001', 15, 'int(__thiscall*)(void*, const char *ansi, wchar_t *unicode, int buffer_size)'
)
function ilocalize.ansi_to_unicode(ansi, unicode, buffer_size)
return ConvertAnsiToUnicode(ansi, unicode, buffer_size)
end
end
local surface = { } do
local wide = ffi.new 'int[1]'
local tall = ffi.new 'int[1]'
local SetColor = vtable_bind('vguimatsurface.dll', 'VGUI_Surface031', 15, 'void(__thiscall*)(void* thisptr, int r, int g, int b, int a)')
local SetTextFont = vtable_bind('vguimatsurface.dll', 'VGUI_Surface031', 23, 'void(__thiscall*)(void*, unsigned int font_id)')
local SetTextColor = vtable_bind('vguimatsurface.dll', 'VGUI_Surface031', 25, 'void(__thiscall*)(void*, int r, int g, int b, int a)')
local SetTextPos = vtable_bind('vguimatsurface.dll', 'VGUI_Surface031', 26, 'void(__thiscall*)(void*, int x, int y)')
local DrawPrintText = vtable_bind('vguimatsurface.dll', 'VGUI_Surface031', 28, 'void(__thiscall*)(void*, const wchar_t *text, int maxlen, int draw_type)')
local GetFontTall = vtable_bind('vguimatsurface.dll', 'VGUI_Surface031', 74, 'int(__thiscall*)(void*, unsigned int font)')
local GetTextSize = vtable_bind('vguimatsurface.dll', 'VGUI_Surface031', 79, 'void(__thiscall*)(void*, unsigned int font, const wchar_t *text, int &wide, int &tall)')
local DrawFilledRectFade = vtable_bind('vguimatsurface.dll', 'VGUI_Surface031', 123, 'void(__thiscall*)(void*, int x0, int y0, int x1, int y1, unsigned int alpha0, unsigned int alpha1, bool bHorizontal)')
function surface.text_tall(font)
return GetFontTall(font)
end
function surface.measure_text(font, text)
local buffer = ffi.new 'wchar_t[2048]'
ilocalize.ansi_to_unicode(text, buffer, 2048)
GetTextSize(font, buffer, wide, tall)
return wide[0], tall[0]
end
function surface.text(font, x, y, r, g, b, a, text)
local len = #text
if len <= 0 then
return
end
local buffer = ffi.new 'wchar_t[2048]'
ilocalize.ansi_to_unicode(text, buffer, 2048)
SetTextFont(font)
SetTextPos(x, y)
SetTextColor(r, g, b, a)
DrawPrintText(buffer, len, 0)
end
function surface.fade(x, y, w, h, r0, g0, b0, a0, r1, g1, b1, a1, horizontal)
SetColor(r0, g0, b0, a0)
DrawFilledRectFade(x, y, x + w, y + h, 255, 0, horizontal)
SetColor(r1, g1, b1, a1)
DrawFilledRectFade(x, y, x + w, y + h, 0, 255, horizontal)
end
end
local reference = { } do
reference.ragebot = {
weapon_type = ui.reference(
'Rage', 'Weapon type', 'Weapon type'
),
aimbot = {
enabled = {
ui.reference('Rage', 'Aimbot', 'Enabled')
},
double_tap = {
ui.reference('Rage', 'Aimbot', 'Double tap')
},
target_hitbox = ui.reference(
'Rage', 'Aimbot', 'Target hitbox'
),
force_body_aim = ui.reference(
'Rage', 'Aimbot', 'Force body aim'
),
force_safe_point = ui.reference(
'Rage', 'Aimbot', 'Force safe point'
),
minimum_hit_chance = ui.reference(
'Rage', 'Aimbot', 'Minimum hit chance'
),
minimum_damage = ui.reference(
'Rage', 'Aimbot', 'Minimum damage'
),
minimum_damage_override = {
ui.reference('Rage', 'Aimbot', 'Minimum damage override')
},
automatic_scope = ui.reference(
'Rage', 'Aimbot', 'Automatic scope'
)
},
other = {
quick_peek_assist = {
ui.reference('Rage', 'Other', 'Quick peek assist')
},
quick_peek_assist_mode = {
ui.reference('Rage', 'Other', 'Quick peek assist mode')
},
quick_peek_assist_distance = ui.reference(
'Rage', 'Other', 'Quick peek assist distance'
),
duck_peek_assist = ui.reference(
'Rage', 'Other', 'Duck peek assist'
)
}
}
reference.antiaim = {
angles = {
enabled = ui.reference(
'AA', 'Anti-aimbot angles', 'Enabled'
),
pitch = {
ui.reference('AA', 'Anti-aimbot angles', 'Pitch')
},
yaw_base = ui.reference(
'AA', 'Anti-aimbot angles', 'Yaw base'
),
yaw = {
ui.reference('AA', 'Anti-aimbot angles', 'Yaw')
},
yaw_jitter = {
ui.reference('AA', 'Anti-aimbot angles', 'Yaw jitter')
},
body_yaw = {
ui.reference('AA', 'Anti-aimbot angles', 'Body yaw')
},
freestanding_body_yaw = ui.reference(
'AA', 'Anti-aimbot angles', 'Freestanding body yaw'
),
edge_yaw = ui.reference(
'AA', 'Anti-aimbot angles', 'Edge yaw'
),
freestanding = {
ui.reference('AA', 'Anti-aimbot angles', 'Freestanding')
},
roll = ui.reference(
'AA', 'anti-aimbot angles', 'Roll'
)
},
fake_lag = {
enabled = {
ui.reference('AA', 'Fake lag', 'Enabled')
},
amount = ui.reference(
'AA', 'Fake lag', 'Amount'
),
variance = ui.reference(
'AA', 'Fake lag', 'Variance'
),
limit = ui.reference(
'AA', 'Fake lag', 'Limit'
),
},
other = {
slow_motion = {
ui.reference('AA', 'Other', 'Slow motion')
},
on_shot_antiaim = {
ui.reference('AA', 'Other', 'On shot anti-aim')
},
leg_movement = ui.reference(
'AA', 'Other', 'Leg movement'
),
fake_peek = {
ui.reference('AA', 'Other', 'Fake peek')
}
}
}
reference.misc = {
miscellaneous = {
draw_console_output = ui.reference(
'Misc', 'Miscellaneous', 'Draw console output'
),
ping_spike = {
ui.reference('Misc', 'Miscellaneous', 'Ping spike')
},
override_zoom_fov = ui.reference(
'Misc', 'Miscellaneous', 'Override zoom FOV'
)
},
settings = {
menu_color = ui.reference(
'Misc', 'Settings', 'Menu color'
),
dpi_scale = ui.reference(
'Misc', 'Settings', 'DPI scale'
)
}
}
reference.playerlist = {
players = ui.reference(
'Players', 'Players', 'Player list'
),
force_body = ui.reference(
'Players', 'Adjustments', 'Force body yaw'
),
force_body_value = ui.reference(
'Players', 'Adjustments', 'Force body yaw value'
),
reset = ui.reference(
'Players', 'Players', 'Reset all'
)
}
function reference.get_dpi()
local matched = string.match(
ui.get(reference.misc.settings.dpi_scale), '(%d+)%%'
)
if not matched then
return 0
end
return matched * 0.01
end
function reference.get_color(to_hex)
if to_hex then
return utils.to_hex(ui.get(reference.misc.settings.menu_color))
end
return ui.get(reference.misc.settings.menu_color)
end
function reference.get_override_damage()
local item = reference.ragebot.aimbot.minimum_damage_override[3]
if item == nil then return reference.get_minimum_damage() end
local ok, value = pcall(ui.get, item)
return ok and tonumber(value) or reference.get_minimum_damage()
end
function reference.get_minimum_damage()
local item = reference.ragebot.aimbot.minimum_damage
if item == nil then return 0 end
local ok, value = pcall(ui.get, item)
return ok and tonumber(value) or 0
end
function reference.is_freestanding()
return ui.get(reference.antiaim.angles.freestanding[1])
and ui.get(reference.antiaim.angles.freestanding[2])
end
function reference.is_slow_motion()
return ui.get(reference.antiaim.other.slow_motion[1])
and ui.get(reference.antiaim.other.slow_motion[2])
end
function reference.is_double_tap_active()
return ui.get(reference.ragebot.aimbot.double_tap[1])
and ui.get(reference.ragebot.aimbot.double_tap[2])
end
function reference.is_override_minimum_damage()
local items = reference.ragebot.aimbot.minimum_damage_override
if items[1] == nil or items[2] == nil then return false end
local ok_enabled, enabled = pcall(ui.get, items[1])
local ok_hotkey, active = pcall(ui.get, items[2])
return ok_enabled and ok_hotkey and enabled == true and active == true
end
function reference.is_on_shot_antiaim_active()
return ui.get(reference.antiaim.other.on_shot_antiaim[1])
and ui.get(reference.antiaim.other.on_shot_antiaim[2])
end
function reference.is_duck_peek_assist()
return ui.get(reference.ragebot.other.duck_peek_assist)
end
function reference.is_quick_peek_assist()
return ui.get(reference.ragebot.other.quick_peek_assist[1])
and ui.get(reference.ragebot.other.quick_peek_assist[2])
end
end
local event_system = { } do
local function find(list, value)
for i = 1, #list do
if value == list[i] then
return i
end
end
return nil
end
local EventList = { } do
EventList.__index = EventList
function EventList:new()
return setmetatable({
list = { },
count = 0
}, self)
end
function EventList:__len()
return self.count
end
function EventList:set(callback)
if not find(self.list, callback) then
self.count = self.count + 1
table.insert(self.list, callback)
end
return self
end
function EventList:unset(callback)
local index = find(self.list, callback)
if index ~= nil then
self.count = self.count - 1
table.remove(self.list, index)
end
return self
end
function EventList:fire(...)
local list = self.list
for i = 1, #list do
local ok, err = pcall(list[i], ...)
if not ok then client.error_log('[aetheryx] event bus error: ' .. tostring(err)) end
end
return self
end
end
local EventBus = { } do
local function __index(list, k)
local value = rawget(list, k)
if value == nil then
value = EventList:new()
rawset(list, k, value)
end
return value
end
function EventBus:new()
return setmetatable({ }, {
__index = __index
})
end
end
function event_system:new()
return EventBus:new()
end
end
local ui_callback = { } do
local lookup = { }
function ui_callback.set(item, callback, force_call)
if lookup[item] == nil then
local list = { }
ui.set_callback(item, function()
for i = 1, #list do
local ok, err = pcall(list[i], item)
if not ok then client.error_log('[aetheryx] ui callback error: ' .. tostring(err)) end
end
end)
lookup[item] = list
end
local index = contains(lookup[item], callback)
if index == nil then
table.insert(lookup[item], callback)
end
if force_call then
callback(item)
end
return item
end
function ui_callback.unset(item, callback)
local list = lookup[item]
if list == nil then
return
end
local index = contains(list, callback)
if index ~= nil then
table.remove(list, index)
end
return item
end
end
local theme_controller = { } do
local function tohex(r, g, b, a)
return string.format(
'%02x%02x%02x%02x',
r, g, b, a or 255
)
end
local invokers = { }
local menu_color = ui.reference(
'Misc', 'Settings', 'Menu color'
)
local hex = tohex(ui.get(menu_color))
local Wrapper = { } do
Wrapper.__index = Wrapper
function Wrapper:__call()
local repl = string.format(
'\a%s%%1\a%s', hex, 'FFFFFFC8'
)
local result = string.gsub(
self.text, '${(.-)}', repl
)
return result
end
function Wrapper:new(text)
return setmetatable({
text = text
}, self)
end
end
local function table_pack(...)
local result = { }
for i = 1, select('#', ...) do
result[i] = select(i, ...)
end
return result
end
local function update_invoker(invoker)
local args = invoker.args
invoker.item:set(invoker.callback(
unpack(args, 1, table.maxn(args))
))
end
function theme_controller.wrap(text)
return Wrapper:new(text)
end
function theme_controller.update()
for i = 1, #invokers do
update_invoker(invokers[i])
end
end
function theme_controller.push(item, callback, ...)
local invoker = {
item = item,
args = table_pack(...),
callback = callback
}
update_invoker(invoker)
table.insert(invokers, invoker)
end
local callbacks do
local function on_menu_color(item)
hex = tohex(ui.get(item))
theme_controller.update()
end
ui_callback.set(menu_color, on_menu_color)
end
end
local ragebot = { } do
local item_data = { }
local ref_weapon_type = ui.reference(
'Rage', 'Weapon type', 'Weapon type'
)
local e_hotkey_mode = {
[0] = 'Always on',
[1] = 'On hotkey',
[2] = 'Toggle',
[3] = 'Off hotkey'
}
local function get_value(item)
local type = ui.type(item)
local value = { ui.get(item) }
if type == 'hotkey' then
local mode = e_hotkey_mode[value[2]]
local keycode = value[3] or 0
return { mode, keycode }
end
return value
end
function ragebot.set(item, ...)
local weapon_type = ui.get(ref_weapon_type)
if item_data[item] == nil then
item_data[item] = { }
end
local data = item_data[item]
if data[weapon_type] == nil then
data[weapon_type] = {
type = weapon_type,
value = get_value(item)
}
end
ui.set(item, ...)
end
function ragebot.unset(item)
local data = item_data[item]
if data == nil then
return
end
local weapon_type = ui.get(ref_weapon_type)
for k, v in pairs(data) do
ui.set(ref_weapon_type, v.type)
ui.set(item, unpack(v.value))
data[k] = nil
end
ui.set(ref_weapon_type, weapon_type)
item_data[item] = nil
end
end
local override = { } do
local item_data = { }
local e_hotkey_mode = {
[0] = 'Always on',
[1] = 'On hotkey',
[2] = 'Toggle',
[3] = 'Off hotkey'
}
local function get_value(item)
local type = ui.type(item)
local value = { ui.get(item) }
if type == 'hotkey' then
local mode = e_hotkey_mode[value[2]]
local keycode = value[3] or 0
return { mode, keycode }
end
return value
end
function override.get(item)
local value = item_data[item]
if value == nil then
return nil
end
return unpack(value)
end
function override.set(item, ...)
if item_data[item] == nil then
item_data[item] = get_value(item)
end
ui.set(item, ...)
end
function override.unset(item)
local value = item_data[item]
if value == nil then
return
end
ui.set(item, unpack(value))
item_data[item] = nil
end
end
local logging = { } do
local SCRIPT_NAME = script.name
local SOUND_SUCCESS = 'ui\\beepclear.wav'
local SOUND_FAILURE = 'resource\\warning.wav'
local play = cvar.play
local function display_tag(r, g, b)
local text = string.format(
'[%s]',
SCRIPT_NAME
)
client.color_log(r, g, b, text, ' \0')
end
function logging.log(msg)
display_tag(240, 240, 240)
client.color_log(255, 255, 255, msg)
end
function logging.success(msg)
display_tag(reference.get_color())
client.color_log(255, 255, 255, msg)
play:invoke_callback(SOUND_SUCCESS)
end
function logging.error(msg)
display_tag(250, 50, 75)
client.color_log(255, 255, 255, msg)
play:invoke_callback(SOUND_FAILURE)
end
end
local localdb = { } do
local BASE64_KEY = '41IwhiXV5v3eaJfgk6SrW0ROKolCMYEUcGBPmb9xzu2HZLjDFys8dpntTQNqA7+/='
local PATH = '.'
local FILE = PATH .. '\\aetheryx_db.dat'
local store = { }
local function read_file()
local ok, data = pcall(readfile, FILE)
if ok and type(data) == 'string' and data ~= '' then
return data
end
if old_ok and type(old_data) == 'string' and old_data ~= '' then
return old_data
end
return nil
end
local function write_file(str)
local ok, err = pcall(writefile, FILE, str)
if not ok then
logging.error('Unable to write storage: ' .. tostring(err))
return false
end
return true
end
local function encode_data(data)
local ok, result = pcall(
json.stringify, data
)
if not ok then
return false, result
end
ok, result = pcall(
base64.encode, result, BASE64_KEY
)
if not ok then
return false, result
end
return true, result
end
local function decode_data(data)
if type(data) ~= 'string' or #data > 524288 then
return false, 'storage payload is invalid or too large'
end
local ok, result = pcall(
base64.decode, data, BASE64_KEY
)
if not ok then
return false, result
end
if type(result) ~= 'string' or #result > 524288 then
return false, 'decoded storage payload is invalid or too large'
end
ok, result = pcall(
json.parse, result
)
if not ok or type(result) ~= 'table' then
return false, ok and 'storage root must be a table' or result
end
return true, result
end
local function write_storage(data)
local ok, result = encode_data(data)
if not ok then
logging.error(
'Unable to encode data'
)
return false
end
return write_file(result)
end
local function parse_storage()
local content = read_file()
if content == nil then
if not write_storage { } then
logging.log 'Unable to create db'
end
return { }
end
local ok, result = decode_data(content)
if not ok then
logging.error 'Unable to decode db'
logging.log 'Trying to flush db'
if not write_storage { } then
logging.error 'Unable to flush db'
end
return { }
end
return result
end
local M = { } do
function M:__index(key)
return store[key]
end
function M:__newindex(key, value)
store[key] = value
write_storage(store)
end
end
store = parse_storage()
setmetatable(localdb, M)
end
local VIRTUAL_ITEM_MODE = false
local CURRENT_VIRTUAL_STATE = nil
local builder_value_bank = { }
local active_builder_team = 'T' -- editor-selected team only
local runtime_builder_team = nil -- actual local-player team used by runtime AA
local builder_bank_version = 0
local builder_synced_version = -1
local builder_bank_dirty = false
local sync_physical_from_bank = nil
rawset(_G, '__aetheryx_ui_item_suffix', { })
local function clone_builder_value(value, seen)
if type(value) ~= 'table' then return value end
seen = seen or { }
if seen[value] ~= nil then return seen[value] end
local result = { }
seen[value] = result
for k, v in pairs(value) do
result[clone_builder_value(k, seen)] = clone_builder_value(v, seen)
end
return result
end
local function prune_removed_builder_fields(bank)
if type(bank) ~= 'table' then return false end
local changed=false
for key,value in pairs(bank) do
    if type(key)=='string' and key:match('^sequence_') then
        bank[key]=nil;changed=true
    elseif type(value)=='table' and prune_removed_builder_fields(value) then
        changed=true
    end
end
return changed
end
local function builder_bank_slot(team, state)
local t = builder_value_bank[team]
if t == nil then t = { }; builder_value_bank[team] = t end
local sc = t[state]
if sc == nil then sc = { }; t[state] = sc end
return sc
end

local function builder_editor_profile_team(state)
if state == 'Freestanding' then
return 'BOTH'
end
return active_builder_team
end

local function builder_runtime_profile_team(state)
if state == 'Freestanding' then
return 'BOTH'
end
return runtime_builder_team or active_builder_team
end

local function virtual_item_values(self)
if self.__vstate ~= nil and self.__vsuffix ~= nil then
local profile_team = builder_runtime_profile_team(self.__vstate)
local tb = builder_value_bank[profile_team]
local sb = tb ~= nil and tb[self.__vstate] or nil
local v = sb ~= nil and sb[self.__vsuffix] or nil
if v ~= nil then return v end
end
return self.value
end
local function make_virtual_menu_item(fn, argv)
local vtype, default = 'unknown', { }
if fn == ui.new_checkbox then vtype, default = 'checkbox', { false }
elseif fn == ui.new_slider then vtype, default = 'slider', { argv[6] ~= nil and argv[6] or argv[4] or 0 }
elseif fn == ui.new_combobox then
vtype = 'combobox'
local opt = argv[4]
if type(opt) == 'table' then opt = opt[1] end
default = { opt }
elseif fn == ui.new_multiselect then vtype, default = 'multiselect', { { } }
elseif fn == ui.new_textbox then vtype, default = 'textbox', { '' }
elseif fn == ui.new_hotkey then vtype, default = 'hotkey', { false }
elseif fn == ui.new_color_picker then vtype, default = 'color picker', { argv[4], argv[5], argv[6], argv[7] }
elseif fn == ui.new_label then vtype = 'label'
elseif fn == ui.new_button then vtype = 'button'
end
local item = { ref = nil, type = vtype, value = default, default = default, is_virtual = true }
function item:get(key)
if self.type == 'label' or self.type == 'button' or self.type == 'unknown' then return nil end
local vals = virtual_item_values(self)
if key ~= nil then
local sel = vals[1]
if type(sel) ~= 'table' then return false end
for i = 1, #sel do if sel[i] == key then return true end end
return false
end
return unpack(vals)
end
function item:set(...)
if self.type == 'label' or self.type == 'button' or self.type == 'unknown' then return end
local vals = { ... }
if self.__vstate ~= nil and self.__vsuffix ~= nil then
local profile_team = builder_editor_profile_team(self.__vstate)
builder_bank_slot(profile_team, self.__vstate)[self.__vsuffix] = vals
builder_bank_version = builder_bank_version + 1
else
self.value = vals
end
end
function item:set_callback() end
function item:unset_callback() end
function item:update() end
function item:reset() self:set(unpack(self.default)) end
return item
end
local config_system = { } do
local BASE64_KEY = 'bjW9MagJsut5xDz36Hvl74nC8Eoy0GIUVX2NLQepckFfrBYOhRZKAwmSqidP1T+/='
local HOTKEY_MODE = {
[0] = 'Always on',
[1] = 'On hotkey',
[2] = 'Toggle',
[3] = 'Off hotkey'
}
local item_list = { }
local item_data = { }
local function get_item_value(item)
if item.type == 'hotkey' then
local _, mode, key = item:get()
return { HOTKEY_MODE[mode], key or 0 }
end
return { item:get() }
end
local function get_key_values(arr)
local list = { }
if arr ~= nil then
for i = 1, #arr do
list[arr[i]] = i
end
end
return list
end
function config_system.push(tab, name, item)
local ui_suffix = type(name) == 'string' and name:match('^UI:(.+)$') or nil
if ui_suffix ~= nil then
rawget(_G, '__aetheryx_ui_item_suffix')[item] = ui_suffix
return item
end
if VIRTUAL_ITEM_MODE and type(item) == 'table' and item.is_virtual then
item.__vstate = CURRENT_VIRTUAL_STATE
if CURRENT_VIRTUAL_STATE ~= nil and type(name) == 'string'
and name:sub(1, #CURRENT_VIRTUAL_STATE + 1) == CURRENT_VIRTUAL_STATE .. ':' then
item.__vsuffix = name:sub(#CURRENT_VIRTUAL_STATE + 2)
end
end
if item_data[tab] == nil then
item_data[tab] = { }
end
local data = {
tab = tab,
name = name,
item = item
}
if item_data[tab][name] ~= nil then
client.error_log(string.format(
'config collision: [ %s, %s ]',
tab, name
))
end
item_data[tab][name] = item
table.insert(item_list, data)
return item
end
function config_system.encode(data)
local ok, result = pcall(
json.stringify, data
)
if not ok then
return false, result
end
ok, result = pcall(
base64.encode,
result,
BASE64_KEY
)
if not ok then
return false, result
end
return true, string.format(
'aetheryx_v2_%s_', result
)
end
function config_system.decode(str)
local data = str:match('^aetheryx_v2_(.-)_$')
if data == nil then
return false, 'Invalid config'
end
local ok, result = pcall(
base64.decode,
data,
BASE64_KEY
)
if not ok then
return false, result
end
ok, result = pcall(
json.parse, result
)
if not ok then
return false, result
end
return true, result
end
function config_system.import(data, categories)
if data == nil then
return false, 'config is empty'
end
local keys = get_key_values(categories)

-- Builder V2 stores the complete team bank. This prevents presets from
-- accidentally saving/loading only the currently selected T or CT side.
local builder_payload = type(data.Builder) == 'table' and data.Builder.__team_bank or nil
if type(builder_payload) == 'table' and (categories == nil or keys.Builder ~= nil) then
builder_value_bank = clone_builder_value(builder_payload)
prune_removed_builder_fields(builder_value_bank)
builder_value_bank.T = builder_value_bank.T or { }
builder_value_bank.CT = builder_value_bank.CT or { }
builder_value_bank.BOTH = builder_value_bank.BOTH or { }
builder_bank_version = builder_bank_version + 1
builder_bank_dirty = true
if sync_physical_from_bank ~= nil then
pcall(sync_physical_from_bank)
end
end

for k, v in pairs(data) do
if categories ~= nil and keys[k] == nil then
goto continue
end
-- New-format builder data has already been restored atomically above.
if k == 'Builder' and type(v) == 'table' and type(v.__team_bank) == 'table' then
goto continue
end
-- Backward compatibility: old configs stored only one virtual Builder view.
-- Import those values into BOTH T and CT instead of whichever editor side
-- happens to be selected when the config is loaded.
if k == 'Builder' and type(v) == 'table' then
local items = item_data[k]
if items ~= nil then
for m, n in pairs(v) do
local item = items[m]
if item ~= nil and item.__vstate ~= nil and item.__vsuffix ~= nil then
if item.__vstate == 'Freestanding' then
builder_bank_slot('BOTH', item.__vstate)[item.__vsuffix] = clone_builder_value(n)
else
builder_bank_slot('T', item.__vstate)[item.__vsuffix] = clone_builder_value(n)
builder_bank_slot('CT', item.__vstate)[item.__vsuffix] = clone_builder_value(n)
end
end
end
builder_bank_version = builder_bank_version + 1
builder_bank_dirty = true
if sync_physical_from_bank ~= nil then pcall(sync_physical_from_bank) end
end
goto continue
end
local items = item_data[k]
if items == nil then
goto continue
end
for m, n in pairs(v) do
local item = items[m]
if item ~= nil then
pcall(item.set, item, unpack(n))
end
end
::continue::
end
return true, nil
end
function config_system.export(categories)
local list = { }
local keys = get_key_values(categories)
for k, v in pairs(item_data) do
if categories ~= nil and keys[k] == nil then
goto continue
end
-- Builder is exported as one complete T/CT bank below.
if k == 'Builder' then
goto continue
end
local values = { }
for m, n in pairs(v) do
values[m] = get_item_value(n)
end
list[k] = values
::continue::
end
if categories == nil or keys.Builder ~= nil then
local export_bank=clone_builder_value(builder_value_bank)
prune_removed_builder_fields(export_bank)
list.Builder = { __team_bank = export_bank }
end
return list
end
end
local menu = { } do
local event_bus = event_system:new()
local CHECKBOX_GEAR = '\a6C7078A0\aDEFAULT'
local function decorate_checkbox_name(name)
local visible, key = name:match('^(.-)(\n.*)$')
if visible == nil then
visible = name
key = ''
end
if visible == '' or visible:find('', 1, true) ~= nil then
return name
end
return string.format('%s  %s%s', visible, CHECKBOX_GEAR, key)
end
local Item = { } do
Item.__index = Item
local function pack(ok, ...)
if not ok then
return nil
end
return ...
end
local function get_value_array(ref)
return { pack(pcall(ui.get, ref)) }
end
local function get_key_values(arr)
local list = { }
for i = 1, #arr do
list[arr[i]] = i
end
return list
end
local function update_item_values(item, initial)
local value = get_value_array(item.ref)
item.value = value
if initial then
item.default = value
end
if item.type == 'multiselect' then
item.key_values = get_key_values(unpack(value))
end
end
function Item:new(ref)
return setmetatable({
ref = ref,
type = nil,
list = { },
value = { },
default = { },
key_values = { },
callbacks = { }
}, self)
end
function Item:init(...)
local function callback()
update_item_values(self, false)
self:fire_events()
event_bus.item_changed:fire(self)
end
self.type = ui.type(self.ref)
local can_have_callback = (
self.type ~= 'label' and
self.type ~= 'unknown'
)
if can_have_callback then
update_item_values(self, true)
pcall(ui.set_callback, self.ref, callback)
end
if self.type == 'multiselect' or self.type == 'list' then
self.list = select(4, ...)
end
if self.type == 'button' then
local fn = select(4, ...)
if fn ~= nil then
self:set_callback(fn)
end
end
event_bus.item_init:fire(self)
end
function Item:get(key)
local values = get_value_array(self.ref)
if key ~= nil then
local selected = values[1]
if type(selected) ~= 'table' then return false end
for i = 1, #selected do
if selected[i] == key then return true end
end
return false
end
return unpack(values)
end
function Item:set(...)
ui.set(self.ref, ...)
update_item_values(self, false)
end
function Item:update(...)
ui.update(self.ref, ...)
end
function Item:reset()
pcall(ui.set, self.ref, unpack(self.default))
end
function Item:set_enabled(value)
return ui.set_enabled(self.ref, value)
end
function Item:set_visible(value)
return ui.set_visible(self.ref, value)
end
function Item:set_callback(callback, force_call)
local index = contains(self.callbacks, callback)
if index == nil then
table.insert(self.callbacks, callback)
end
if force_call then
callback(self)
end
return self
end
function Item:unset_callback(callback)
local index = contains(self.callbacks, callback)
if index ~= nil then
table.remove(self.callbacks, index)
end
return self
end
function Item:fire_events()
local list = self.callbacks
for i = 1, #list do
local ok, err = pcall(list[i], self)
if not ok then client.error_log('[aetheryx] item callback error: ' .. tostring(err)) end
end
end
end
function menu.new(fn, ...)
local argv, argc = { }, select('#', ...)
for i = 1, argc do
argv[i] = select(i, ...)
end
if VIRTUAL_ITEM_MODE then
return make_virtual_menu_item(fn, argv)
end
if fn == ui.new_button and type(argv[4]) ~= 'function' then
argv[4] = DUMMY
end
if fn == ui.new_checkbox and type(argv[4]) == 'string' then
argv[4] = decorate_checkbox_name(argv[4])
end
local ref = fn(unpack(argv, 1, argc))
local item = Item:new(ref) do
item:init(...)
end
return item
end
function menu.get_event_bus()
return event_bus
end
end
-- Native compact controls for the legacy GameSense menu.
-- This intentionally uses the same internal menu layout used by the existing
-- Aetheryx AA icon patch and the inline helper supplied for this build.
local aetheryx_native_inline = { bindings = { } }
do
local MENU_BASE = 0x434799AC

-- The compact menu helper touches GameSense native UI objects. Lua pcall cannot
-- catch a native access violation, so validate every address before reading or
-- writing it. If GameSense rebuilds an element, the compact placement is simply
-- skipped until the script is reloaded instead of dereferencing a stale pointer.
pcall(ffi.cdef, [[
typedef struct {
    void* BaseAddress;
    void* AllocationBase;
    unsigned long AllocationProtect;
    size_t RegionSize;
    unsigned long State;
    unsigned long Protect;
    unsigned long Type;
} AETHERYX_MEMORY_BASIC_INFORMATION;
size_t __stdcall VirtualQuery(
    const void* lpAddress,
    AETHERYX_MEMORY_BASIC_INFORMATION* lpBuffer,
    size_t dwLength
);
]])
local aetheryx_kernel32 = nil
do
local ok, lib = pcall(ffi.load, 'kernel32')
if ok then aetheryx_kernel32 = lib end
end

local function native_memory_ok(addr, size)
addr = tonumber(addr) or 0
size = math.max(1, tonumber(size) or 1)
if addr < 0x10000 then return false end
if aetheryx_kernel32 == nil then
return addr >= 0x10000000 and addr <= 0x7FFFFFFF
end
local mbi = ffi.new('AETHERYX_MEMORY_BASIC_INFORMATION[1]')
local ok, result = pcall(
aetheryx_kernel32.VirtualQuery,
ffi.cast('const void*', addr),
mbi,
ffi.sizeof(mbi[0])
)
if not ok or tonumber(result) == 0 then return false end
if tonumber(mbi[0].State) ~= 0x1000 then return false end -- MEM_COMMIT
local protect = tonumber(mbi[0].Protect) or 0
if bit.band(protect, 0x100) ~= 0 or bit.band(protect, 0x01) ~= 0 then
return false -- PAGE_GUARD / PAGE_NOACCESS
end
local base = tonumber(ffi.cast('uintptr_t', mbi[0].BaseAddress)) or 0
local region = tonumber(mbi[0].RegionSize) or 0
return addr >= base and (addr + size) <= (base + region)
end

local function rptr(addr)
if not native_memory_ok(addr, ffi.sizeof('uintptr_t')) then return 0 end
return tonumber(ffi.cast('uintptr_t*', addr)[0]) or 0
end

local function rint(addr)
if not native_memory_ok(addr, 4) then return 0 end
return tonumber(ffi.cast('int32_t*', addr)[0]) or 0
end

local function rbyte(addr)
if not native_memory_ok(addr, 1) then return -1 end
return tonumber(ffi.cast('uint8_t*', addr)[0]) or -1
end

local function snapshot_elements()
local out = { }
local ok = pcall(function()
local tabs_begin = rptr(MENU_BASE + 0x54)
local tabs_end = rptr(MENU_BASE + 0x58)
if tabs_begin < 0x10000000 or tabs_end <= tabs_begin then return end
local tabs_count = math.floor((tabs_end - tabs_begin) / 4)
if tabs_count < 1 or tabs_count > 32 then return end

for ti = 0, tabs_count - 1 do
local tab_ptr = rptr(tabs_begin + ti * 4)
if tab_ptr > 0x10000000 then
local childs_begin = rptr(tab_ptr + 0x70)
local childs_end = rptr(tab_ptr + 0x74)
if childs_begin > 0x10000000 and childs_end >= childs_begin then
local childs_count = math.floor((childs_end - childs_begin) / 4)
if childs_count >= 0 and childs_count <= 256 then
for ci = 0, childs_count - 1 do
local child_ptr = rptr(childs_begin + ci * 4)
if child_ptr > 0x10000000 then
local els_begin = rptr(child_ptr + 0x80)
local els_end = rptr(child_ptr + 0x84)
if els_begin > 0x10000000 and els_end >= els_begin then
local els_count = math.floor((els_end - els_begin) / 4)
if els_count >= 0 and els_count <= 1024 then
for ei = 0, els_count - 1 do
local el_ptr = rptr(els_begin + ei * 4)
if el_ptr > 0x10000000 then
out[el_ptr] = {
type_b = rbyte(el_ptr + 0x19),
x = rint(el_ptr + 0x20),
y = rint(el_ptr + 0x24),
w = rint(el_ptr + 0x28),
h = rint(el_ptr + 0x2C),
-- The native object pointer may change after GameSense rebuilds a
-- conditional group.  The menu-tree slot itself is stable, so keep it as a
-- deterministic fingerprint for the few controls that explicitly opt into
-- safe rebinding.
tab_index = ti,
child_index = ci,
element_index = ei
}
end
end
end
end
end
end
end
end
end
end
end)
if not ok then return { } end
return out
end

local function resolve_new(before, wanted_type)
local after = snapshot_elements()
local candidates = { }
for ptr, meta in pairs(after) do
if before[ptr] == nil and (wanted_type == nil or meta.type_b == wanted_type) then
candidates[#candidates + 1] = { ptr = ptr, meta = meta }
end
end
if #candidates == 1 then
return candidates[1].ptr, candidates[1].meta
end
-- ui.new_* normally inserts synchronously. If an unrelated element was also
-- inserted, prefer the most recently positioned candidate (largest y).
if #candidates > 1 then
table.sort(candidates, function(a, b)
if a.meta.y == b.meta.y then return a.meta.x > b.meta.x end
return a.meta.y > b.meta.y
end)
return candidates[1].ptr, candidates[1].meta
end
return nil, nil
end

function aetheryx_native_inline.create(opts, fn, ...)
opts = opts or { }
local before = snapshot_elements()
local item = menu.new(fn, ...)
local ptr, meta = resolve_new(before, opts.native_type)
local binding = {
item = item,
ptr = ptr,
before = before,
opts = opts,
base_x = meta and meta.x or nil,
base_y = meta and meta.y or nil,
base_w = meta and meta.w or nil,
base_h = meta and meta.h or nil,
last_target_y = nil,
slot_tab = meta and meta.tab_index or nil,
slot_child = meta and meta.child_index or nil,
slot_element = meta and meta.element_index or nil,
slot_type = meta and meta.type_b or nil
}
aetheryx_native_inline.bindings[#aetheryx_native_inline.bindings + 1] = binding
return item
end

local function binding_for_item(item)
if item == nil then return nil end
for i = 1, #aetheryx_native_inline.bindings do
local b = aetheryx_native_inline.bindings[i]
if b.item == item then return b end
if type(item) == 'table' and b.item == item.ref then return b end
if type(b.item) == 'table' and b.item.ref == item then return b end
if type(item) == 'table' and type(b.item) == 'table' and item.ref ~= nil and b.item.ref == item.ref then return b end
end
return nil
end

local function apply_binding(binding)
local ptr = binding.ptr
if ptr == nil or ptr <= 0x10000000 then return end
local opts = binding.opts or { }
if opts.track_only == true then return end

pcall(function()
local current_x = rint(ptr + 0x20)
local current_y = rint(ptr + 0x24)
local current_w = rint(ptr + 0x28)
local current_h = rint(ptr + 0x2C)

local w = tonumber(opts.w) or 70
local h = tonumber(opts.h) or 18
local x = tonumber(opts.x)
local y = tonumber(opts.y)

if opts.anchor_item ~= nil then
local anchor_binding = binding_for_item(opts.anchor_item)
if anchor_binding ~= nil and anchor_binding.ptr ~= nil and anchor_binding.ptr > 0x10000000 then
local aptr = anchor_binding.ptr
local ax = rint(aptr + 0x20)
local ay = rint(aptr + 0x24)
local aw = rint(aptr + 0x28)
local ah = rint(aptr + 0x2C)
if ah <= 0 then ah = 18 end

if opts.anchor_below == true then
x = x or (ax + (tonumber(opts.dx) or 0))
y = y or (ay + ah + (tonumber(opts.gap) or 5) + (tonumber(opts.dy) or 0))
elseif opts.anchor_right == true and aw > 0 and aw < 140 then
-- Anchoring to the right of another small button (e.g. Save next to Load)
x = x or (ax + aw + (tonumber(opts.gap) or 6) + (tonumber(opts.dx) or 0))
y = y or (ay + math.floor((ah - h) * 0.5) + (tonumber(opts.dy) or 0))
else
-- Anchoring on the same row as a checkbox
y = y or (ay + math.floor((ah - h) * 0.5) + (tonumber(opts.dy) or 0))
if x == nil then
if opts.dx ~= nil then
x = ax + tonumber(opts.dx)
else
x = 160
end
end
end
else
return
end
else
if x == nil then
x = (binding.base_x or current_x) + (tonumber(opts.dx) or 0)
end
if y == nil then
local row_shift = tonumber(opts.dy)
if row_shift == nil and opts.align_previous ~= false then
row_shift = -(h + (tonumber(opts.row_gap) or 2))
end
y = (binding.base_y or current_y) + (row_shift or 0)
end
end

w = math.max(1, math.min(1000, w))
h = math.max(1, math.min(200, h))
x = math.max(-4096, math.min(16384, x))
y = math.max(-4096, math.min(16384, y))

ffi.cast('int32_t*', ptr + 0x20)[0] = math.floor(x + 0.5)
ffi.cast('int32_t*', ptr + 0x24)[0] = math.floor(y + 0.5)
ffi.cast('int32_t*', ptr + 0x28)[0] = math.floor(w + 0.5)
ffi.cast('int32_t*', ptr + 0x2C)[0] = math.floor(h + 0.5)

pcall(function()
ffi.cast('int32_t*', ptr + 0x30)[0] = math.floor(w + 0.5)
ffi.cast('int32_t*', ptr + 0x34)[0] = math.floor(h + 0.5)
end)

if opts.same_line ~= false then
pcall(function()
ffi.cast('uint8_t*', ptr + 0x18)[0] = 1
end)
end
end)
end

function aetheryx_native_inline.apply()
if not ui.is_menu_open() then return end

-- Resolve any missing pointers once in paint_ui exactly as in message (2).txt
for i = 1, #aetheryx_native_inline.bindings do
local binding = aetheryx_native_inline.bindings[i]
if binding.ptr == nil and binding.before ~= nil then
local after = snapshot_elements()
for ptr, meta in pairs(after) do
if binding.before[ptr] == nil and (binding.opts.native_type == nil or meta.type_b == binding.opts.native_type) then
local claimed = false
for j = 1, #aetheryx_native_inline.bindings do
if aetheryx_native_inline.bindings[j] ~= binding and aetheryx_native_inline.bindings[j].ptr == ptr then
claimed = true
break
end
end
if not claimed and ptr > 0x10000000 then
binding.ptr = ptr
binding.base_x = meta.x
binding.base_y = meta.y
binding.base_w = meta.w
binding.base_h = meta.h
break
end
end
end
end
end

for i = 1, #aetheryx_native_inline.bindings do
local binding = aetheryx_native_inline.bindings[i]
if binding.ptr ~= nil and binding.ptr > 0x10000000 and binding.opts.track_only ~= true then
apply_binding(binding)
end
end
end
end

local menu_logic = { } do
local item_data, item_list, item_lookup, visibility_cache = { }, { }, { }, { }
local update_pending, update_running = false, false
local logic_events = event_system:new()
function menu_logic.get_event_bus() return logic_events end
function menu_logic.set(item, value)
if item == nil or item.ref == nil then return end
item_data[item.ref] = value == true
end
function menu_logic.animate_next() update_pending = true end
local function set_visible_cached(item, value)
local ref = item and item.ref
if ref == nil or visibility_cache[ref] == value then return end
local ok, err = pcall(item.set_visible, item, value)
if ok then visibility_cache[ref] = value
else client.error_log('[aetheryx] visibility error: ' .. tostring(err)) end
end
function menu_logic.force_update()
for i = 1, #item_list do
local item = item_list[i]
if item ~= nil and item.ref ~= nil then
local value = item_data[item.ref]
if value ~= nil then set_visible_cached(item, value); item_data[item.ref] = false end
end
end
end
local function flush_update()
if not update_pending or update_running then return end
update_pending, update_running = false, true
local ok, err = pcall(function()
logic_events.update:fire()
menu_logic.force_update()
end)
update_running = false
if not ok then client.error_log('[aetheryx] menu update error: ' .. tostring(err)) end
end
local menu_events = menu.get_event_bus() do
local function on_item_init(item)
local ref = item and item.ref
if ref == nil then return end
item_data[ref] = false
set_visible_cached(item, false)
if item_lookup[ref] == nil then item_lookup[ref] = item; item_list[#item_list + 1] = item end
end
local function on_item_changed() update_pending = true end
menu_events.item_init:set(on_item_init)
menu_events.item_changed:set(on_item_changed)
end
__aetheryx_runtime.set('paint_ui', flush_update)
end
local text_anims = { } do
local function u8(str)
local chars = { }
local count = 0
for c in string.gmatch(str, '.[\128-\191]*') do
count = count + 1
chars[count] = c
end
return chars, count
end
function text_anims.gradient(str, time, r1, g1, b1, a1, r2, g2, b2, a2)
local list = { }
local strbuf, strlen = u8(str)
local div = 1 / (strlen - 1)
local delta_r = r2 - r1
local delta_g = g2 - g1
local delta_b = b2 - b1
local delta_a = a2 - a1
for i = 1, strlen do
local char = strbuf[i]
local t = time do
t = t % 2
if t > 1 then
t = 2 - t
end
end
local r = r1 + t * delta_r
local g = g1 + t * delta_g
local b = b1 + t * delta_b
local a = a1 + t * delta_a
local hex = utils.to_hex(r, g, b, a)
table.insert(list, '\a')
table.insert(list, hex)
table.insert(list, char)
time = time + div
end
return table.concat(list)
end
end
local text_fmt = { } do
local function decompose(str)
local result, len = { }, #str
local i, j = str:find('\a', 1)
if i == nil then
table.insert(result, {
str, nil
})
end
if i ~= nil and i > 1 then
table.insert(result, {
str:sub(1, i - 1), nil
})
end
while i ~= nil do
local hex = nil
if str:sub(j + 1, j + 7) == 'DEFAULT' then
j = j + 8
else
hex = str:sub(j + 1, j + 8)
j = j + 9
end
local m, n = str:find('\a', j)
if m == nil then
if j <= len then
table.insert(result, {
str:sub(j), hex
})
end
break
end
table.insert(result, {
str:sub(j, m - 1), hex
})
i, j = m, n
end
return result
end
function text_fmt.color(str)
local list = decompose(str)
local len = #list
return list, len
end
end
local localplayer = { } do
local pre_flags = 0
local post_flags = 0
localplayer.is_moving = false
localplayer.is_onground = false
localplayer.is_crouched = false
localplayer.body_yaw = 0
localplayer.sent_packets = 0
localplayer.duck_amount = 0.0
localplayer.velocity = vector()
localplayer.velocity2d_sqr = 0
localplayer.move_dir = vector()
localplayer.eye_position = vector()
localplayer.is_peeking = false
localplayer.is_vulnerable = false
local function is_peeking(player)
local should, vulnerable = false, false
local velocity = vector(entity.get_prop(player, 'm_vecVelocity'))
local eye = vector(client.eye_position())
local peye = utils.extrapolate(eye, velocity, 14)
local enemies = entity.get_players(true)
for i = 1, #enemies do
local enemy = enemies[i]
local esp_data = entity.get_esp_data(enemy)
if esp_data == nil then
goto continue
end
if bit.band(esp_data.flags, bit.lshift(1, 11)) ~= 0 then
vulnerable = true
goto continue
end
local head = vector(entity.hitbox_position(enemy, 0))
local phead = utils.extrapolate(head, velocity, 4)
local entindex, damage = client.trace_bullet(player, peye.x, peye.y, peye.z, phead.x, phead.y, phead.z)
if damage ~= nil and damage > 0 then
should = true
break
end
::continue::
end
return should, vulnerable
end
local function get_body_yaw(player)
-- Actual local body/desync delta is eye_angles_y - goal_feet_yaw.
-- Keep the old netprop path only as a crash-safe fallback during spawn/map transitions.
local ok_info, entity_info = pcall(c_entity, player)
if ok_info and entity_info ~= nil then
local ok_state, anim_state = pcall(entity_info.get_anim_state, entity_info)
if ok_state and anim_state ~= nil then
local eye_angles_y = tonumber(anim_state.eye_angles_y)
local goal_feet_yaw = tonumber(anim_state.goal_feet_yaw)
if eye_angles_y ~= nil and goal_feet_yaw ~= nil then
return utils.normalize(eye_angles_y - goal_feet_yaw, -180, 180)
end
end
end

local ok_eye, pitch, eye_yaw = pcall(entity.get_prop, player, 'm_angEyeAngles')
local ok_lby, lby = pcall(entity.get_prop, player, 'm_flLowerBodyYawTarget')
if ok_eye and ok_lby and type(eye_yaw) == 'number' and type(lby) == 'number' then
return utils.normalize(eye_yaw - lby, -180, 180)
end
return 0
end
local function on_pre_predict_command(cmd)
local me = entity.get_local_player()
if me == nil then
return
end
pre_flags = entity.get_prop(me, 'm_fFlags')
end
local function on_predict_command(cmd)
local me = entity.get_local_player()
if me == nil then
return
end
post_flags = entity.get_prop(me, 'm_fFlags')
end
local function on_setup_command(cmd)
local me = entity.get_local_player()
if me == nil then
return
end
local is_onground = bit.band(pre_flags, 1) ~= 0
and bit.band(post_flags, 1) ~= 0
local velocity = vector(entity.get_prop(me, 'm_vecVelocity'))
local duck_amount = entity.get_prop(me, 'm_flDuckAmount')
local velocity2d_sqr = velocity:length2dsqr()
localplayer.is_moving = velocity2d_sqr > 5 * 5
localplayer.is_onground = is_onground
if cmd.chokedcommands == 0 then
localplayer.body_yaw = get_body_yaw(me)
localplayer.sent_packets = (
localplayer.sent_packets + 1
)
localplayer.eye_position = client.eye_position()
localplayer.is_crouched = duck_amount > 0.5
localplayer.duck_amount = duck_amount
end
localplayer.velocity = velocity
localplayer.velocity2d_sqr = velocity2d_sqr
localplayer.move_dir = vector(
cmd.forwardmove, cmd.sidemove, 0
)
end
function localplayer.update_peek_state(player)
local peeking, vulnerable = is_peeking(player)
localplayer.is_peeking = peeking
localplayer.is_vulnerable = vulnerable
return peeking, vulnerable
end
__aetheryx_runtime.set('pre_predict_command', on_pre_predict_command)
__aetheryx_runtime.set('predict_command', on_predict_command)
__aetheryx_runtime.set('setup_command', on_setup_command)
end
local exploit = { } do
local BREAK_LAG_COMPENSATION_DISTANCE_SQR = 64 * 64
local max_tickbase = 0
local run_command_number = 0
local data = {
old_origin = vector(),
old_simtime = 0.0,
shift = false,
breaking_lc = false,
active = false,
charged = false,
defensive = {
force = false,
left = 0,
max = 0,
active = false,
},
lagcompensation = {
distance = 0.0,
history_distance = 0.0,
teleport = false,
state = -1
}
}
local lc_history = { }
local LC_HISTORY_TICKS = math.max(1, math.floor(1 / globals.tickinterval() + 0.5))
local function update_tickbase(me)
data.shift = globals.tickcount() > entity.get_prop(me, 'm_nTickBase')
end
local function update_teleport(old_origin, new_origin)
local delta = new_origin - old_origin
local distance = delta:lengthsqr()
local is_teleport = distance > BREAK_LAG_COMPENSATION_DISTANCE_SQR
data.breaking_lc = is_teleport
data.lagcompensation.distance = distance
data.lagcompensation.teleport = is_teleport
end
local function update_lagcompensation(me)
local old_origin = data.old_origin
local old_simtime = data.old_simtime
local ox, oy, oz = entity.get_origin(me)
local simulation_time = entity.get_prop(me, 'm_flSimulationTime')
if ox == nil or simulation_time == nil then return end
local origin = vector(ox, oy, oz)
local simtime = toticks(simulation_time)
if old_simtime ~= nil then
local delta = simtime - old_simtime
if delta < 0 or delta > 0 and delta <= 64 then
update_teleport(old_origin, origin)
end
end
lc_history[#lc_history + 1] = { tick = simtime, origin = origin }
while #lc_history > 1 and simtime - lc_history[1].tick > LC_HISTORY_TICKS do
table.remove(lc_history, 1)
end
local first = lc_history[1]
local history_distance = first ~= nil and (origin - first.origin):lengthsqr() or 0
local vx, vy = entity.get_prop(me, 'm_vecVelocity')
local speed = math.sqrt((vx or 0) ^ 2 + (vy or 0) ^ 2)
local state = -1
if history_distance > BREAK_LAG_COMPENSATION_DISTANCE_SQR then
state = 1
elseif speed > 255 and #lc_history >= math.max(2, math.floor(LC_HISTORY_TICKS * 0.75)) then
state = 0
end
data.lagcompensation.history_distance = history_distance
data.lagcompensation.state = state
data.breaking_lc = data.lagcompensation.teleport or state == 1
data.old_origin = origin
data.old_simtime = simtime
end
local function update_defensive_tick(me)
local tickbase = entity.get_prop(me, 'm_nTickBase')
if math.abs(tickbase - max_tickbase) > 64 then
max_tickbase = 0
end
local defensive_ticks_left = 0
if tickbase > max_tickbase then
max_tickbase = tickbase
elseif max_tickbase > tickbase then
defensive_ticks_left = math.min(14, math.max(0, max_tickbase - tickbase - 1))
end
if defensive_ticks_left > 0 then
data.breaking_lc = true
data.defensive.left = defensive_ticks_left
data.defensive.active = true
if data.defensive.max == 0 then
data.defensive.max = defensive_ticks_left
end
else
data.defensive.left = 0
data.defensive.max = 0
data.defensive.active = false
end
end
local function update_charged(me)
local m_nTickBase = entity.get_prop(me, 'm_nTickBase')
local shift = math.floor(m_nTickBase - globals.tickcount() - 3 - toticks(client.latency()) * 0.4)
local fakelag_limit = ui.get(reference.antiaim.fake_lag.limit)
local wanted = -15 + (fakelag_limit - 1) + 5
data.charged = shift <= wanted
end
local function update_active()
local doubletap_active = reference.is_double_tap_active()
local hideshots_active = reference.is_on_shot_antiaim_active()
data.active = doubletap_active or hideshots_active
end
function exploit.get()
return data
end
local function on_predict_command(cmd)
local me = entity.get_local_player()
if me == nil then
return
end
if cmd.command_number == run_command_number then
update_defensive_tick(me)
run_command_number = nil
end
end
local function on_setup_command(cmd)
local me = entity.get_local_player()
if me == nil then
return
end
update_charged(me)
update_active()
end
local function on_run_command(e)
local me = entity.get_local_player()
if me == nil then
return
end
update_tickbase(me)
run_command_number = e.command_number
end
local function on_net_update_start()
local me = entity.get_local_player()
if me == nil then
return
end
update_lagcompensation(me)
end
__aetheryx_runtime.set('predict_command', on_predict_command)
__aetheryx_runtime.set('setup_command', on_setup_command)
__aetheryx_runtime.set('run_command', on_run_command)
__aetheryx_runtime.set('net_update_start', on_net_update_start)
end
local conditions = { } do
local list = { }
local stable_state = nil
local pending_state = nil
local pending_ticks = 0
local landing_ticks = 0
local STATE_CONFIRM_TICKS = 2
local LANDING_CONFIRM_TICKS = 2
local function get_raw_state(cmd)
local jump_pressed = cmd ~= nil and (cmd.in_jump == 1 or cmd.in_jump == true)
local is_air = not localplayer.is_onground or jump_pressed
local duck_amount = localplayer.duck_amount or 0
local is_crouched = localplayer.is_crouched or duck_amount >= 0.65
if is_air then
return is_crouched and 'Air & Crouched' or 'Air'
end
if is_crouched then
return localplayer.is_moving and 'Crouching & Move' or 'Crouching'
end
if localplayer.is_moving then
if reference.is_slow_motion() then
return 'Slow Walk'
end
return 'Moving'
end
return 'Standing'
end
local function set_stable_state(state)
stable_state = state
pending_state = nil
pending_ticks = 0
landing_ticks = 0
end
local function update_stable_state(raw_state)
if stable_state == nil then
set_stable_state(raw_state)
return
end
if raw_state == stable_state then
pending_state = nil
pending_ticks = 0
landing_ticks = 0
return
end
local stable_is_air = stable_state == 'Air' or stable_state == 'Air & Crouched'
local raw_is_air = raw_state == 'Air' or raw_state == 'Air & Crouched'
if raw_is_air and not stable_is_air then
set_stable_state(raw_state)
return
end
if stable_is_air and not raw_is_air then
landing_ticks = landing_ticks + 1
if landing_ticks >= LANDING_CONFIRM_TICKS then
set_stable_state(raw_state)
end
return
end
landing_ticks = 0
if pending_state ~= raw_state then
pending_state = raw_state
pending_ticks = 1
return
end
pending_ticks = pending_ticks + 1
if pending_ticks >= STATE_CONFIRM_TICKS then
set_stable_state(raw_state)
end
end
function conditions.get()
return list
end
local function on_setup_command(cmd)
local raw_state = get_raw_state(cmd)
update_stable_state(raw_state)
list[1] = stable_state or raw_state
for i = 2, #list do
list[i] = nil
end
end
__aetheryx_runtime.set(
'setup_command',
on_setup_command
)
end
local menu_elements = { } do
local conditions = {
'Shared',
'Standing',
'Moving',
'Slow Walk',
'Crouching',
'Crouching & Move',
'Air',
'Air & Crouched',
'Freestanding',
'Legit AA',
}
local function new_key(str, key)
if str:find '\n' == nil then
str = str .. '\n'
end
return str .. key
end
local function lock_clr()
return utils.to_hex(75, 75, 75, 255)
end
local function def_clr()
return utils.to_hex(200, 200, 200, 255)
end
local function accent_clr()
return reference.get_color(true)
end
local function polished_title(icon, title, suffix)
local compact = suffix or title or 'AETHERYX'
return string.format(
'\a%s%s  \a%s%s',
accent_clr(),
icon,
def_clr(),
compact
)
end
local category_selector = { } do
menu_elements.category_selector = category_selector
-- Main Aetheryx workspace selector. It stays wider than the Anti-Aim
-- Builder/Features selector that is placed to its right below.
category_selector.brand = menu.new(
ui.new_label, 'AA', 'Fake lag',
new_key(string.format('\a%s¨˜”*°• aetheryx •°*”˜¨', reference.get_color(true)), 'category_selector brand')
)
local category_labels = {
['anti-aim'] = '✦ anti-aim',
['misc'] = '⚙ misc',
['config'] = '▣ config'
}
local category_keys = {
['✦ anti-aim'] = 'anti-aim',
['⚙ misc'] = 'misc',
['▣ config'] = 'config'
}
category_selector.categories = menu.new(
ui.new_combobox, 'AA', 'Fake lag', new_key('\n', 'category_selector state'), {
category_labels['anti-aim'], category_labels.misc, category_labels.config
}
)
local function refresh_category_scene()
menu_logic.animate_next()
menu_logic.get_event_bus().update:fire()
menu_logic.force_update()
end
category_selector.categories:set_callback(refresh_category_scene)
function category_selector.current()
local value = category_selector.categories:get()
return category_keys[value] or value
end
function category_selector.select(name)
if name == 'Anti-aimbot angles' then name = 'anti-aim' end
if name == 'Others' then name = 'misc' end
if name == 'Configs' then name = 'config' end
if name ~= 'anti-aim' and name ~= 'misc' and name ~= 'config' then
return
end
local display = category_labels[name]
if category_selector.categories:get() ~= display then
category_selector.categories:set(display)
else
refresh_category_scene()
end
end
category_selector.select('anti-aim')
local last_brand_update_time = 0
client.set_event_callback('paint_ui', function()
local now = globals.realtime()
if ui.is_menu_open() and (now - last_brand_update_time >= 0.05) then
last_brand_update_time = now
category_selector.brand:set(string.format('\a%s¨˜”*°• aetheryx •°*”˜¨', reference.get_color(true)))
end
end)
end
-- Keep the stock GameSense Anti-Aim sidebar icon.
-- Older Aetheryx builds could leave a native tab patch alive during a hot reload;
-- restore it once and remove every custom icon/navigation hook from this build.
do
local previous_patch = rawget(_G, '__aetheryx_native_tab_patch')
if type(previous_patch) == 'table' and type(previous_patch.restore) == 'function' then
pcall(previous_patch.restore)
end
rawset(_G, '__aetheryx_native_tab_patch', nil)
rawset(_G, '__aetheryx_independent_tab_active', false)
rawset(_G, '__aetheryx_native_tab_selected', false)
end

-- Animated menu brand: short shine sweep + subtle pulse.
-- It only updates while the GameSense menu is open.
local aetheryx_brand_anim = {
labels = { },
last_update = 0
}

local function brand_hex_channel(hex, pos, fallback)
local value = tonumber(string.sub(hex or '', pos, pos + 1), 16)
return value or fallback
end

local function brand_color_hex(r, g, b, a)
return string.format(
'%02X%02X%02X%02X',
utils.clamp(math.floor(r + 0.5), 0, 255),
utils.clamp(math.floor(g + 0.5), 0, 255),
utils.clamp(math.floor(b + 0.5), 0, 255),
utils.clamp(math.floor(a + 0.5), 0, 255)
)
end

local function brand_mix_to_white(r, g, b, amount)
amount = utils.clamp(amount or 0, 0, 1)
return
r + (255 - r) * amount,
g + (255 - g) * amount,
b + (255 - b) * amount
end

function aetheryx_brand_anim.build()
local now = globals.realtime()
local base = tostring(reference.get_color(true) or 'A8FF38FF')

-- Menu-color helpers normally return RRGGBBAA.
if #base < 8 then
base = base .. string.rep('F', 8 - #base)
end

local br = brand_hex_channel(base, 1, 168)
local bg = brand_hex_channel(base, 3, 255)
local bb = brand_hex_channel(base, 5, 56)
local ba = brand_hex_channel(base, 7, 255)

local pulse = 0.5 + 0.5 * math.sin(now * 4.2)
local sr, sg, sb = brand_mix_to_white(br, bg, bb, 0.30 + pulse * 0.24)
local star = brand_color_hex(sr, sg, sb, ba)

local name = 'aetheryx'
-- Extra travel space makes the shine disappear briefly before looping.
local sweep = (now * 5.2) % (#name + 4) - 1.5
local pieces = {
'\a', base, '(ﾉ◕ヮ◕)ﾉ*:･ﾟ',
'\a', star, '✧ '
}

for i = 1, #name do
local distance = math.abs(i - sweep)
local shine = utils.clamp(1 - distance / 1.65, 0, 1)

-- Tiny background pulse + a bright localized sweep.
local mix = 0.05 + pulse * 0.04 + shine * 0.88
local r, g, b = brand_mix_to_white(br, bg, bb, mix)
local alpha = ba

pieces[#pieces + 1] = '\a'
pieces[#pieces + 1] = brand_color_hex(r, g, b, alpha)
pieces[#pieces + 1] = string.sub(name, i, i)
end

return table.concat(pieces)
end

function aetheryx_brand_anim.bind(label)
if label == nil then
return
end

aetheryx_brand_anim.labels[#aetheryx_brand_anim.labels + 1] = label
label:set(aetheryx_brand_anim.build())
end

__aetheryx_runtime.set('paint_ui', function()
if not ui.is_menu_open() then
return
end

local now = globals.realtime()
if now - aetheryx_brand_anim.last_update < 0.04 then
return
end
aetheryx_brand_anim.last_update = now

local value = aetheryx_brand_anim.build()
for i = 1, #aetheryx_brand_anim.labels do
local label = aetheryx_brand_anim.labels[i]
if label ~= nil then
label:set(value)
end
end
end)

local home = { } do
menu_elements.home = home
local config_local = { } do
home.config_local = config_local
local function name_author_label()
return string.format(
'\a%s%s \a%s~  \a%sAuthor \a%s| \a%s%s',
reference.get_color(true),
'',
lock_clr(),
def_clr(),
lock_clr(),
reference.get_color(true),
'1'
)
end
local function name_data_label()
return string.format(
'\a%s%s \a%s~  \a%sCreated at \a%s| \a%s%s',
reference.get_color(true),
'',
lock_clr(),
def_clr(),
lock_clr(),
reference.get_color(true),
'09.07.2025'
)
end
local welcome = { } do
config_local.welcome = welcome
local wrapper_user_label = theme_controller.wrap(new_key(string.format(
'${}  WELCOME BACK, %s',
string.upper(tostring(script.user or 'USER'))
), 'config_local_welcome'))
local wrapper_status_label = theme_controller.wrap(new_key(
'${•}  AETHERYX IS READY  \a6C7078FF/  all systems loaded',
'config_local_status'
))
welcome.user = menu.new(
ui.new_label, 'AA', 'Fake lag', wrapper_user_label()
)
welcome.status = menu.new(
ui.new_label, 'AA', 'Fake lag', wrapper_status_label()
)
theme_controller.push(welcome.user, wrapper_user_label)
theme_controller.push(welcome.status, wrapper_status_label)
end
config_local.config_title = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', new_key(
polished_title('', 'CONFIGS', 'LOCAL PRESETS'),
'config_local_title'
)
)
-- Keep the complete config system on native full-width controls. Custom inline
-- sizing made the list and action buttons tiny or invisible on some DPI scales.
config_local.list = menu.new(
ui.new_listbox, 'AA', 'Anti-aimbot angles', new_key('\n List', 'config_local'), {'', ''}
)
config_local.separator = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'config_local')
)
config_local.author = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', name_author_label()
)
config_local.data = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', name_data_label()
)
config_local.input = menu.new(
ui.new_textbox, 'AA', 'Anti-aimbot angles', new_key('Config name', 'config_local')
)
config_local.load = menu.new(
ui.new_button, 'AA', 'Anti-aimbot angles', 'Load config', DUMMY
)
config_local.save = menu.new(
ui.new_button, 'AA', 'Anti-aimbot angles', 'Save config', DUMMY
)
config_local.import = menu.new(
ui.new_button, 'AA', 'Anti-aimbot angles', 'Import config', DUMMY
)
config_local.export = menu.new(
ui.new_button, 'AA', 'Anti-aimbot angles', 'Export config', DUMMY
)
config_local.delete = menu.new(
ui.new_button, 'AA', 'Anti-aimbot angles', 'Delete config', DUMMY
)
local callbacks do
local ref_menu_color = ui.reference(
'Misc', 'Settings', 'Menu color'
)
local function on_menu_color(item)
config_local.author:set(name_author_label())
config_local.data:set(name_data_label())
end
ui_callback.set(
ref_menu_color,
on_menu_color
)
end
end
end
local other = { } do
menu_elements.other = other
local selector = { } do
other.selector = selector
selector.separator = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'other selector')
)
selector.brand = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles',
new_key(string.format('\a%s(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧ aetheryx',reference.get_color(true)), 'other selector brand')
)
aetheryx_brand_anim.bind(selector.brand)
selector.tab_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Type label', 'other selector')
)
selector.tab = menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Type', 'other selector'), {'Settings'}
)

selector.separator2 = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator2', 'other selector')
)
local callbacks do
local ref_menu_color = ui.reference(
'Misc', 'Settings', 'Menu color'
)
local function get_label_tab()
local icon = ''
selector.tab_label:set(string.format(
'Type \a%s ~  \a%s%s',
lock_clr(), reference.get_color(true), icon
))
end
local function on_menu_color()
get_label_tab()
selector.brand:set(aetheryx_brand_anim.build())
end
selector.tab:set_callback(function()
menu_logic.animate_next()
get_label_tab()
end)
ui_callback.set(ref_menu_color, on_menu_color)
get_label_tab()
end
end
local visual = { } do
other.visual = visual
visual.section_header = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles',
new_key('  Visuals', 'visual_section_header')
)
visual.section_separator = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles',
new_key('────────────────', 'visual_section_separator')
)
visual.tab_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles',
new_key('\n Type label', 'visual_tab')
)
visual.tab = menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles',
new_key('\n Type', 'visual_tab'), {'General'}
)
visual.tab_separator = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles',
new_key('\n Module separator', 'visual_tab')
)
local function update_visual_tab_label()
local icon = ''
visual.tab_label:set(string.format(
'Type \a%s ~  \a%s%s',
lock_clr(), reference.get_color(true), icon
))
end
visual.tab:set_callback(function()
menu_logic.animate_next()
update_visual_tab_label()
end)
update_visual_tab_label()
visual.min_damage_indicator = config_system.push(
'Visuals', 'min_damage_indicator.checkbox', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Min damage indicator', 'min_damage_indicator')
)
)
visual.min_damage_color = config_system.push(
'Visuals', 'min_damage_indicator.color', menu.new(
ui.new_color_picker, 'AA', 'Anti-aimbot angles', new_key('~ color', 'min_damage_indicator_color'), 255, 255, 255, 255
)
)
visual.event_logs = config_system.push(
'Visuals', 'event_logs.checkbox', aetheryx_native_inline.create(
{ track_only = true, rebind = true },
ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('aimbot logs', 'visual_event_logs')
)
)
visual.event_log_show_screen=config_system.push(
'Visuals','event_logs.show_screen',menu.new(
ui.new_checkbox,'AA','Anti-aimbot angles',new_key('Logs on screen','visual_event_logs_show_screen')
)
)
visual.event_log_text_color=config_system.push(
'Visuals','event_logs.text_color',menu.new(
ui.new_color_picker,'AA','Anti-aimbot angles',new_key('~ color','visual_event_logs_color'),217,217,219,255
)
)
-- Style and Reset are created at the end of the Visuals native flow and then
-- compacted back onto the log rows. This keeps GameSense from reserving empty
-- rows between "aimbot logs" and "show on screen".
-- Glow and duration are intentionally fixed internally (35%, 5s) so they no
-- longer take space in the menu.
visual.event_log_show_screen:set(true)

visual.animated_zoom = config_system.push(
'Visuals', 'animated_zoom.checkbox', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Animated zoom', 'visual_animated_zoom')
)
)
visual.animated_zoom_amount = config_system.push(
'Visuals', 'animated_zoom.amount', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('↪ Zoom amount', 'visual_animated_zoom'),
1, 40, 12, true, '°'
)
)
visual.animated_zoom_speed = config_system.push(
'Visuals', 'animated_zoom.speed', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('↪ Zoom speed', 'visual_animated_zoom'),
2, 30, 12, true, 'x'
)
)
visual.center_indicators = config_system.push(
'Visuals', 'center_indicators.enabled', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles',
new_key('Center indicators', 'visual_center_indicators')
)
)
visual.center_indicator_style = config_system.push(
'Visuals', 'center_indicators.style', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles',
new_key('↪ Style', 'visual_center_indicators'), {
'Stars', 'Original', 'Japanese', 'Aetheryx', 'Renewed'
}
)
)
visual.center_indicator_color_1 = config_system.push(
'Visuals', 'center_indicators.renewed_color_1', menu.new(
ui.new_color_picker, 'AA', 'Anti-aimbot angles',
new_key('\n Primary color', 'visual_center_indicators_renewed_color_1'), 184, 178, 225, 255
)
)
visual.center_indicator_color_2 = config_system.push(
'Visuals', 'center_indicators.renewed_color_2', menu.new(
ui.new_color_picker, 'AA', 'Anti-aimbot angles',
new_key('\n Secondary color', 'visual_center_indicators_renewed_color_2'), 255, 255, 255, 255
)
)
visual.center_indicator_offset = config_system.push(
'Visuals', 'center_indicators.offset', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('↪ Offset', 'visual_center_indicators_offset'), 1, 80, 5, true, 'px', 5
)
)
visual.center_indicator_style:set('Stars')

-- Compact event-log style selector. It is created at the end of the Visuals
-- native flow so it does not reserve a blank row, then it is visually anchored
-- into the old Reset slot on the aimbot-logs row.
visual.event_log_style = config_system.push(
'Visuals', 'event_logs.style', aetheryx_native_inline.create(
{ w = 85, h = 18, x = 155, anchor_item = visual.event_logs, same_line = true },
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n', 'visual_event_logs_style'), {
'Default', 'Mini', 'Modern'
}
)
)
visual.event_log_style:set('Modern')

-- Aetheryx Glass HUD -------------------------------------------------------
visual.glass_hud = config_system.push(
'Visuals', 'glass_hud.enabled', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles',
new_key('Glass HUD', 'visual_glass_hud')
)
)
visual.glass_hud_elements = config_system.push(
'Visuals', 'glass_hud.elements', menu.new(
ui.new_multiselect, 'AA', 'Anti-aimbot angles',
new_key('↪ Elements', 'visual_glass_hud_elements'), {
'Watermark', 'Keybinds'
}
)
)
visual.glass_hud:set(true)
visual.glass_hud_elements:set({'Watermark', 'Keybinds'})

end

local aimbot_helper = { } do
other.aimbot_helper = aimbot_helper
aimbot_helper.section_header = menu.new(
ui.new_label, 'AA', 'Fake lag',
new_key('  Ragebot', 'ragebot_section_header')
)
aimbot_helper.section_separator = menu.new(
ui.new_label, 'AA', 'Fake lag',
new_key('────────────────', 'ragebot_section_separator')
)
local weapon_list = {
'Auto Snipers','Scout','AWP','R8 Revolver','Desert Eagle',
'Pistols','Rifle','Shotgun','SMG','Machine gun'
}
local trigger_list = {
'Enemy HP < X','X missed shots','Lethal','Height advantage','Enemy higher than you'
}

aimbot_helper.checkbox = config_system.push('Rage','aimbot_helper.checkbox',menu.new(
ui.new_checkbox,'AA','Fake lag',new_key('Aimbot helper','aimbot_helper')
))
aimbot_helper.miss_reasons = config_system.push('Rage','aimbot_helper.miss_reasons',menu.new(
ui.new_multiselect,'AA','Fake lag',new_key('~ Count miss reasons','helper_reasons'),{'Unknown','Unregistered','Resolver','Other'}
))
aimbot_helper.miss_reasons:set({'Unknown','Unregistered','Resolver'})
aimbot_helper.miss_decay = config_system.push('Rage','aimbot_helper.miss_decay',menu.new(
ui.new_slider,'AA','Fake lag',new_key('~ Miss memory','helper_memory'),3,60,15,true,'s'
))
aimbot_helper.lethal_margin = config_system.push('Rage','aimbot_helper.lethal_margin',menu.new(
ui.new_slider,'AA','Fake lag',new_key('~ Lethal margin','helper_lethal'),0,20,0,true,'hp'
))
aimbot_helper.weapons = menu.new(
ui.new_combobox,'AA','Fake lag',new_key('↪ Weapon','aimbot_helper'),weapon_list
)

local function helper_group(weapon,key,title)
local id = string.format('aimbot_helper.%s[%s]',key,weapon)
local g = { }
g.triggers = config_system.push('Rage',id..'.triggers',menu.new(
ui.new_multiselect,'AA','Fake lag',new_key('↪ '..title,id),trigger_list
))
g.hp = config_system.push('Rage',id..'.hp',menu.new(
ui.new_slider,'AA','Fake lag',new_key('↪ HP',id..'.hp'),1,100,30,true
))
g.missed_shots = config_system.push('Rage',id..'.misses',menu.new(
ui.new_slider,'AA','Fake lag',new_key('↪ Missed shots',id..'.misses'),1,10,2,true
))
return g
end

for i=1,#weapon_list do
local weapon = weapon_list[i]
local id = string.format('aimbot_helper[%s]',weapon)
local items = { }
items.options = config_system.push('Rage',id..'.options',menu.new(
ui.new_multiselect,'AA','Fake lag',new_key('↪ Options',id),{
'Force safe point','Prefer body aim','Force body aim','Ping spike'
}
))
items.force_safe_point = helper_group(weapon,'force_safe_point','Force safe point')
items.prefer_body_aim = helper_group(weapon,'prefer_body_aim','Prefer body aim')
items.force_body_aim = helper_group(weapon,'force_body_aim','Force body aim')
items.ping_spike = { value = config_system.push('Rage',id..'.ping',menu.new(
ui.new_slider,'AA','Fake lag',new_key('↪ Ping spike',id..'.ping'),1,200,100,true,'ms'
)) }
aimbot_helper[weapon] = items
end
end

-- ============================================================================
-- Force Shot -- global GameSense control using the supplied Neverlose trigger
-- behaviour. One bind/value is reused automatically for every weapon profile.
-- ============================================================================
local force_shot = { } do
other.force_shot = force_shot

-- Keep the main switch as a tracked native row; the compact hitchance slider is
-- created last and visually anchored into the right half of this exact row.
force_shot.checkbox = config_system.push('Rage', 'force_shot.enabled', aetheryx_native_inline.create(
{ track_only = true },
ui.new_checkbox, 'Rage', 'Aimbot', new_key('Force Shot', 'force_shot.enabled')
))

force_shot.hotkey = config_system.push('Rage', 'force_shot.hotkey', menu.new(
ui.new_hotkey, 'Rage', 'Aimbot', new_key('↪ Force Shot bind', 'force_shot.hotkey')
))
pcall(ui.set, force_shot.hotkey.ref or force_shot.hotkey, 'On hotkey')

-- This option only changes the SSG-08 exception. With it disabled the supplied
-- Neverlose logic also forces the shot while the Scout is airborne.
force_shot.on_ground = config_system.push('Rage', 'force_shot.on_ground', menu.new(
ui.new_checkbox, 'Rage', 'Aimbot', new_key('↪ Scout On Ground', 'force_shot.on_ground')
))

force_shot.minimum_hitchance = config_system.push('Rage', 'force_shot.minimum_hitchance', aetheryx_native_inline.create(
{
    w = 112,
    h = 10,
    anchor_item = force_shot.checkbox,
    right_pad = 0,
    -- Keep the hitchance bar on the same Force Shot row, but move it farther
    -- to the right so it no longer crowds the checkbox label.
    dx = 78,
    rebind = true,
    rebind_relative_to = force_shot.checkbox,
    relative_slot_delta = 3
},
ui.new_slider, 'Rage', 'Aimbot', new_key('\n Minimum Hit Chance', 'force_shot.minimum_hitchance'),
0, 100, 20, true, '%'
))
end

-- Spectre Lagrecord Update -------------------------------------------------
-- Packet-cycle implementation ported from Spectre; the original Teleport Fix
-- control was intentionally not copied because Spectre contains no runtime
-- reference to that checkbox.
local lagrecord_update = { } do
other.lagrecord_update = lagrecord_update
lagrecord_update.enabled = config_system.push(
'Rage', 'lagrecord_update.enabled', menu.new(
ui.new_checkbox, 'AA', 'Fake lag',
new_key('Lagrecord update', 'lagrecord_update_enabled')
)
)
lagrecord_update.method = config_system.push(
'Rage', 'lagrecord_update.method', menu.new(
ui.new_combobox, 'AA', 'Fake lag',
new_key('↪ Method', 'lagrecord_update_method'), {
'Network errors',
'Compensation'
}
)
)
lagrecord_update.validate_records = config_system.push(
'Rage', 'lagrecord_update.validate_records', menu.new(
ui.new_checkbox, 'AA', 'Fake lag',
new_key('Validate records before firing', 'lagrecord_validate_records')
)
)
lagrecord_update.max_record_age = config_system.push(
'Rage', 'lagrecord_update.max_record_age', menu.new(
ui.new_slider, 'AA', 'Fake lag',
new_key('↪ Maximum record age', 'lagrecord_max_record_age'),
2, 32, 16, true, 't'
)
)
lagrecord_update.reject_teleport = config_system.push(
'Rage', 'lagrecord_update.reject_teleport', menu.new(
ui.new_checkbox, 'AA', 'Fake lag',
new_key('↪ Reject teleport records', 'lagrecord_reject_teleport')
)
)
lagrecord_update.teleport_distance = config_system.push(
'Rage', 'lagrecord_update.teleport_distance', menu.new(
ui.new_slider, 'AA', 'Fake lag',
new_key('↪ Teleport distance', 'lagrecord_teleport_distance'),
32, 128, 64, true, 'u'
)
)
-- Recommended balanced preset; the parent feature remains opt-in.
lagrecord_update.method:set('Network errors')
lagrecord_update.validate_records:set(true)
lagrecord_update.max_record_age:set(16)
lagrecord_update.reject_teleport:set(true)
lagrecord_update.teleport_distance:set(64)
end


local miscellaneous = { } do
other.miscellaneous = miscellaneous
miscellaneous.section_header = menu.new(
ui.new_label, 'AA', 'Other',
new_key('  Miscellaneous', 'misc_section_header')
)
miscellaneous.section_separator = menu.new(
ui.new_label, 'AA', 'Other',
new_key('────────────────', 'misc_section_separator')
)
miscellaneous.console_filter = config_system.push(
'Miscellaneous', 'console_filter.enabled', menu.new(
ui.new_checkbox, 'AA', 'Other', new_key('Console filter', 'misc_console_filter')
)
)
local animation_breaker = { } do
miscellaneous.animation_breaker=animation_breaker
animation_breaker.checkbox=config_system.push('Miscellaneous','animation_breaker.checkbox',menu.new(ui.new_checkbox,'AA','Other',new_key('Animation Breaker','animation_breaker')))
animation_breaker.triggers=config_system.push('Miscellaneous','animation_breaker.triggers',menu.new(ui.new_multiselect,'AA','Other',new_key('↪ Triggers','animation_breaker'),{'Air','Ground','Tweaks'}))
animation_breaker.air_mode=config_system.push('Miscellaneous','animation_breaker.air.mode',menu.new(ui.new_combobox,'AA','Other',new_key('↪ Air','animation_breaker'),{'Jitter','Static','Broken'}))
animation_breaker.air_amount=config_system.push('Miscellaneous','animation_breaker.air.amount',menu.new(ui.new_slider,'AA','Other',new_key('↪ Air amount','animation_breaker'),0,10,0,true,'%',10))
animation_breaker.ground_mode=config_system.push('Miscellaneous','animation_breaker.ground.mode',menu.new(ui.new_combobox,'AA','Other',new_key('↪ Ground','animation_breaker'),{'Jitter','Static','Modern','Broken'}))
animation_breaker.ground_amount=config_system.push('Miscellaneous','animation_breaker.ground.amount',menu.new(ui.new_slider,'AA','Other',new_key('↪ Ground amount','animation_breaker'),0,10,0,true,'%',10))
animation_breaker.tweaks=config_system.push('Miscellaneous','animation_breaker.tweaks',menu.new(ui.new_multiselect,'AA','Other',new_key('↪ Tweaks','animation_breaker'),{'Lizginka','Body Lean','Earthshake','Movement On Peek Assist'}))
animation_breaker.tweaks_amount=config_system.push('Miscellaneous','animation_breaker.tweaks.amount',menu.new(ui.new_slider,'AA','Other',new_key('↪ Tweaks amount','animation_breaker'),0,10,0,true,'%',10))
end
local viewmodel = { } do
miscellaneous.viewmodel = viewmodel
viewmodel.checkbox = config_system.push(
'Miscellaneous', 'viewmodel.checkbox', aetheryx_native_inline.create(
{ track_only = true, rebind = true },
ui.new_checkbox, 'AA', 'Other', new_key('Viewmodel', 'viewmodel')
)
)
viewmodel.reset = nil
viewmodel.fov = config_system.push(
'Miscellaneous', 'viewmodel.fov', menu.new(
ui.new_slider, 'AA', 'Other', new_key('↪ Field of view', 'viewmodel'), 0, 1000, 680, true, '°', 0.1
)
)
viewmodel.offset_x = config_system.push(
'Miscellaneous', 'viewmodel.offset_x', menu.new(
ui.new_slider, 'AA', 'Other', new_key('↪ Offset X', 'viewmodel'), -100, 100, 0, true, '', 0.1
)
)
viewmodel.offset_y = config_system.push(
'Miscellaneous', 'viewmodel.offset_y', menu.new(
ui.new_slider, 'AA', 'Other', new_key('↪ Offset Y', 'viewmodel'), -100, 100, 0, true, '', 0.1
)
)
viewmodel.offset_z = config_system.push(
'Miscellaneous', 'viewmodel.offset_z', menu.new(
ui.new_slider, 'AA', 'Other', new_key('↪ Offset Z', 'viewmodel'), -100, 100, 0, true, '', 0.1
)
)
viewmodel.options = config_system.push(
'Miscellaneous', 'viewmodel.options', menu.new(
ui.new_checkbox, 'AA', 'Other', new_key('↪ Opposite knife hand', 'viewmodel')
)
)
end
local bullet_tracer = { } do
miscellaneous.bullet_tracer = bullet_tracer
bullet_tracer.checkbox = config_system.push(
'Miscellaneous', 'bullet_tracer.enabled', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Bullet tracer', 'bullet_tracer')
)
)
bullet_tracer.color = config_system.push(
'Miscellaneous', 'bullet_tracer.color', menu.new(
ui.new_color_picker, 'AA', 'Anti-aimbot angles', new_key('\n Bullet tracer color', 'bullet_tracer_color'), 255, 255, 255, 255
)
)
end
local plus_hitmarker = { } do
miscellaneous.plus_hitmarker = plus_hitmarker
plus_hitmarker.checkbox = config_system.push(
'Miscellaneous', 'plus_hitmarker.enabled', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Plus hitmarker', 'plus_hitmarker')
)
)
end
local hitrate = { } do
miscellaneous.hitrate = hitrate
hitrate.checkbox = config_system.push(
'Miscellaneous', 'hitrate.checkbox', aetheryx_native_inline.create(
{ track_only = true, rebind = true },
ui.new_checkbox, 'AA', 'Other', new_key('Hitrate', 'hitrate')
)
)
-- Reset is created at the end of the Miscellaneous native flow and then
-- visually anchored back onto the Hitrate row. This avoids GameSense reserving
-- a blank native row between Hitrate and Aspect ratio while Reset is visible.
hitrate.reset = nil
end
local aspect_ratio = { } do
miscellaneous.aspect_ratio = aspect_ratio
aspect_ratio.checkbox = config_system.push(
'Miscellaneous', 'aspect_ratio.checkbox', aetheryx_native_inline.create(
{ track_only = true, rebind = true },
ui.new_checkbox, 'AA', 'Other', new_key('Aspect ratio', 'aspect_ratio')
)
)
aspect_ratio.value = nil
end
local remove_sleeves = { } do
miscellaneous.remove_sleeves = remove_sleeves
remove_sleeves.checkbox = config_system.push(
'Miscellaneous', 'remove_sleeves.enabled', menu.new(
ui.new_checkbox, 'AA', 'Other', new_key('Remove sleeves', 'remove_sleeves')
)
)
end
local game_enhancer = { } do
miscellaneous.game_enhancer = game_enhancer
game_enhancer.checkbox = config_system.push(
'Miscellaneous', 'game_enhancer.checkbox', menu.new(
ui.new_checkbox, 'AA', 'Other', new_key('FPS optimizer', 'game_enhancer')
)
)
game_enhancer.list = config_system.push(
'Miscellaneous', 'game_enhancer.list', menu.new(
ui.new_multiselect, 'AA', 'Other', new_key('↪ Effects', 'game_enhancer'), {
'Fix chams color',
'Disable dynamic lighting',
'Disable dynamic shadows',
'Disable first-person tracers',
'Disable ragdolls',
'Disable eye gloss',
'Disable eye movement',
'Disable muzzle flash light',
'Enable low CPU audio',
'Disable bloom',
'Disable particles',
'Reduce breakable objects'
}
)
)
game_enhancer.separator = menu.new(
ui.new_label, 'AA', 'Other', new_key('\n Separator', 'game_enhancer')
)
end

-- Create compact Viewmodel/Aspect-ratio controls at the end of the native
-- Miscellaneous flow. Their natural native slots stay out of the active rows,
-- while the helper anchors them back onto their checkbox rows.
if miscellaneous.viewmodel ~= nil then
miscellaneous.viewmodel.reset = aetheryx_native_inline.create(
{ w = 70, h = 18, x = 160, anchor_item = miscellaneous.viewmodel.checkbox, same_line = true, native_type = 2 },
ui.new_button, 'AA', 'Other', 'Reset', DUMMY
)
end

if miscellaneous.aspect_ratio ~= nil then
miscellaneous.aspect_ratio.value = config_system.push(
'Miscellaneous', 'aspect_ratio.value', aetheryx_native_inline.create(
{ w = 100, h = 16, x = 145, anchor_item = miscellaneous.aspect_ratio.checkbox, same_line = true },
ui.new_slider, 'AA', 'Other',
new_key('\n Ratio preset', 'aspect_ratio'),
0, 6, 0, true, '', 1, {
[0] = 'Native',
[1] = '4:3',
[2] = '5:4',
[3] = '3:2',
[4] = '16:10',
[5] = '16:9',
[6] = '21:9'
}
)
)
end

-- Create the inline Hitrate reset last so its native layout slot lives at the
-- end of Miscellaneous instead of creating a visible hole above Aspect ratio.
if miscellaneous.hitrate ~= nil then
miscellaneous.hitrate.reset = aetheryx_native_inline.create(
{ w = 70, h = 18, x = 160, anchor_item = miscellaneous.hitrate.checkbox, same_line = true, native_type = 2 },
ui.new_button, 'AA', 'Other', 'Reset', DUMMY
)
end
end
end
local antiaim = { } do
menu_elements.antiaim = antiaim
local selector = { } do
antiaim.selector = selector
selector.separator = menu.new(
ui.new_label, 'AA', 'Fake lag', new_key('\n Separator', 'antiaim selector')
)
selector.brand = menu.new(
ui.new_label, 'AA', 'Fake lag',
new_key(string.format('\a%s(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧ aetheryx',reference.get_color(true)), 'antiaim selector brand')
)
aetheryx_brand_anim.bind(selector.brand)
selector.tab_label = menu.new(
ui.new_label, 'AA', 'Fake lag', new_key('\n Type label', 'antiaim selector')
)
selector.tab = menu.new(
ui.new_combobox, 'AA', 'Fake lag', new_key('\n', 'antiaim selector'), {'settings', 'builder'}
)
selector.tab:set('settings')

selector.separator2 = menu.new(
ui.new_label, 'AA', 'Fake lag', new_key('\n Separator2', 'antiaim selector')
)
local callbacks do
local ref_menu_color = ui.reference(
'Misc', 'Settings', 'Menu color'
)
local function get_label_tab()
local icon = selector.tab:get() == 'builder' and '' or ''
selector.tab_label:set(string.format(
'Type \a%s ~  \a%s%s',
lock_clr(), reference.get_color(true), icon
))
end
local function on_menu_color()
get_label_tab()
selector.brand:set(aetheryx_brand_anim.build())
end
selector.tab:set_callback(function()
menu_logic.animate_next()
get_label_tab()
end)
ui_callback.set(ref_menu_color, on_menu_color)
get_label_tab()
end
end
local builder = { } do
antiaim.builder = builder
local current_state = conditions[1]
local send_builder_to_team = nil
local function create_anti_bruteforce_items(state)
local items = { }
local function hash(key)
return state .. ':aetheryx_antibrute_' .. key
end

items.checkbox = config_system.push(
'Builder', hash 'enabled', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Anti-Bruteforce', hash 'enabled')
)
)

items.refresh_modifier = config_system.push(
'Builder', hash 'refresh_modifier', menu.new(
ui.new_combobox, 'AA', 'Other',
new_key('Refresh modifier', hash 'refresh_modifier'), {
'Off',
'Adaptive',
'Increase',
'Decrease'
}
)
)

items.refresh_offset = config_system.push(
'Builder', hash 'refresh_offset', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Refresh offset', hash 'refresh_offset')
)
)

items.enforce_delay = config_system.push(
'Builder', hash 'enforce_delay', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Enforce delay period', hash 'enforce_delay')
)
)

-- source source uses internal slider values 9..200 with 0.1 scale;
-- 9 is rendered as "inf.".
items.duration = config_system.push(
'Builder', hash 'duration', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Duration', hash 'duration'),
9, 200, 9, true, 's.', 0.1, {
[9] = 'inf.'
}
)
)

items.memory_enabled = config_system.push('Builder',hash 'memory_enabled',menu.new(
ui.new_checkbox,'AA','Other',new_key('~ Per-enemy memory',hash 'memory_enabled')
))
items.memory_decay = config_system.push('Builder',hash 'memory_decay',menu.new(
ui.new_slider,'AA','Other',new_key('~ Memory decay',hash 'memory_decay'),5,120,20,true,'s'
))
items.memory_radius = config_system.push('Builder',hash 'memory_radius',menu.new(
ui.new_slider,'AA','Other',new_key('~ Near miss radius',hash 'memory_radius'),8,80,48,true,'u'
))
items.memory_rhythm = config_system.push('Builder',hash 'memory_rhythm',menu.new(
ui.new_slider,'AA','Other',new_key('~ Phase 2 rhythm',hash 'memory_rhythm'),1,8,2,true,'t'
))
items.memory_log = config_system.push('Builder',hash 'memory_log',menu.new(
ui.new_checkbox,'AA','Other',new_key('~ Phase console logs',hash 'memory_log')
))
return items
end
local function create_defensive_items(state)
local items = { }
local function hash(key)
return state .. ':defensive_' .. key
end

items.force_break_lc = config_system.push(
'Builder', hash 'force_break_lc', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Force break LC', hash 'force_break_lc')
)
)

items.enabled = config_system.push(
'Builder', hash 'enabled', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Defensive Anti-Aim', hash 'enabled')
)
)

-- Defensive AA: Pitch (AngelWings)
items.pitch = config_system.push(
'Builder', hash 'pitch', menu.new(
ui.new_combobox, 'AA', 'Other',
new_key('Pitch', hash 'pitch'), {
'Off',
'Static',
'Jitter',
'Spin',
'Random',
'Angelic'
}
)
)

items.pitch_label_1 = menu.new(
ui.new_label, 'AA', 'Other',
new_key('  ${~}  offset 1', hash 'pitch_from')
)

items.pitch_offset_1 = config_system.push(
'Builder', hash 'pitch_offset_1', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('\n', hash 'pitch_offset_1'),
-89, 89, 0, true, '°'
)
)

items.pitch_label_2 = menu.new(
ui.new_label, 'AA', 'Other',
new_key('  ${~}  offset 2', hash 'pitch_to')
)

items.pitch_offset_2 = config_system.push(
'Builder', hash 'pitch_offset_2', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('\n', hash 'pitch_offset_2'),
-89, 89, 0, true, '°'
)
)

items.pitch_speed = config_system.push(
'Builder', hash 'pitch_speed', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Speed', hash 'pitch_speed'),
-50, 50, 20, true, nil, 0.1
)
)

-- Defensive AA: Yaw (AngelWings)
items.yaw = config_system.push(
'Builder', hash 'yaw', menu.new(
ui.new_combobox, 'AA', 'Other',
new_key('Yaw', hash 'yaw'), {
'Off',
'Static',
'Spin',
'Random',
'Left/Right',
'Side-based'
}
)
)

items.yaw_offset = config_system.push(
'Builder', hash 'yaw_offset', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Yaw offset', hash 'yaw_offset'),
-180, 180, 0, true, '°'
)
)

items.yaw_left = config_system.push(
'Builder', hash 'yaw_left', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Yaw left', hash 'yaw_left'),
-180, 180, 0, true, '°'
)
)

items.yaw_right = config_system.push(
'Builder', hash 'yaw_right', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Yaw right', hash 'yaw_right'),
-180, 180, 0, true, '°'
)
)

items.yaw_speed = config_system.push(
'Builder', hash 'yaw_speed', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Speed', hash 'yaw_speed'),
-50, 50, 20, true, '', 0.1
)
)

items.yaw_modifier = config_system.push(
'Builder', hash 'yaw_modifier', menu.new(
ui.new_combobox, 'AA', 'Other',
new_key('Yaw modifier', hash 'yaw_modifier'), {
'Off',
'Offset',
'Center',
'Skitter'
}
)
)

items.modifier_offset = config_system.push(
'Builder', hash 'modifier_offset', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Modifier offset', hash 'modifier_offset'),
-180, 180, 0, true, '°'
)
)

items.delay = config_system.push(
'Builder', hash 'delay', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Delay', hash 'delay')
)
)

items.delays = {
config_system.push(
'Builder', hash 'delay_1', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Delay from', hash 'delay_1'),
1, 14, 1, true, 't'
)
),
config_system.push(
'Builder', hash 'delay_2', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('Delay to', hash 'delay_2'),
1, 14, 1, true, 't'
)
)
}

items.delay_affect_modifier = config_system.push(
'Builder', hash 'delay_affect_modifier', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Affect modifier', hash 'delay_affect_modifier')
)
)

items.force_target_yaw = config_system.push(
'Builder', hash 'force_target_yaw', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Force target yaw', hash 'force_target_yaw')
)
)

return items
end
local function create_builder_items(state, std_key)
local items = { }
local is_shared = state == 'Shared'
local is_legit_aa = state == 'Legit AA'
local is_freestanding = state == 'Freestanding'
local function hash(key)
return state .. ':' .. key
end
if std_key ~= nil then
function hash(key)
return state .. ':' .. key .. ':' .. std_key
end
end
if is_shared then
local wrapper_yaw_base_label = theme_controller.wrap(new_key('Yaw base ${»}', hash 'yaw_base'))
items.yaw_base_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_base_label()
)
theme_controller.push(items.yaw_base_label, wrapper_yaw_base_label)
end
if not is_shared then
local enabled_name = state == 'UI' and 'Override condition' or string.format(
'Override %s', state
)
items.enabled = config_system.push(
'Builder', hash 'enabled', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key(
enabled_name, hash 'enabled'
)
)
)
end
if is_legit_aa or state == 'UI' then
items.bomb_e_fix = config_system.push(
'Builder', hash 'bomb_e_fix', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key(
'Bomb E fix', hash 'bomb_e_fix'
)
)
)
end
if not is_freestanding then
items.yaw_base = config_system.push(
'Builder', hash 'yaw_base', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Yaw Base', hash 'yaw_base'), {
'At targets',
'Local view'
}
)
)
local wrapper_yaw_type_label = theme_controller.wrap(new_key('⤿ Yaw ${»}', hash 'yaw_type'))
items.yaw_type_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_type_label()
)
theme_controller.push(items.yaw_type_label, wrapper_yaw_type_label)
items.yaw_type = config_system.push(
'Builder', hash 'yaw_type', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Yaw', hash 'yaw_type'), {
'180',
'Left / Right'
}
)
)
local yaw_between do
local wrapper_between_global_label = theme_controller.wrap(new_key('Global value ${•}', hash 'yaw_between_global'))
items.yaw_between_global_label = menu.new(ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_between_global_label())
theme_controller.push(items.yaw_between_global_label, wrapper_between_global_label)
items.yaw_between_global = config_system.push('Builder', hash 'yaw_between_global', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Global value', hash 'yaw_between_global'), -180, 180, 0, true, '°'
))
local wrapper_between_hold_label = theme_controller.wrap(new_key('Hold tick ${•}', hash 'yaw_between_hold'))
items.yaw_between_hold_label = menu.new(ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_between_hold_label())
theme_controller.push(items.yaw_between_hold_label, wrapper_between_hold_label)
items.yaw_between_hold = config_system.push('Builder', hash 'yaw_between_hold', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Hold tick', hash 'yaw_between_hold'), 1, 10, 3, true, 't'
))
local wrapper_between_switch_label = theme_controller.wrap(new_key('Switch tick ${•}', hash 'yaw_between_switch'))
items.yaw_between_switch_label = menu.new(ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_between_switch_label())
theme_controller.push(items.yaw_between_switch_label, wrapper_between_switch_label)
items.yaw_between_switch = config_system.push('Builder', hash 'yaw_between_switch', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Switch tick', hash 'yaw_between_switch'), 1, 10, 2, true, 't'
))
local wrapper_between_offset_label = theme_controller.wrap(new_key('Switch value ${•}', hash 'yaw_between_offset'))
items.yaw_between_offset_label = menu.new(ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_between_offset_label())
theme_controller.push(items.yaw_between_offset_label, wrapper_between_offset_label)
items.yaw_between_offset = config_system.push('Builder', hash 'yaw_between_offset', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Switch value', hash 'yaw_between_offset'), -180, 180, 45, true, '°'
))
end
local yaw_180 do
local wrapper_yaw_180_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'yaw_180_offset'))
items.yaw_180_offset_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_180_offset_label()
)
theme_controller.push(items.yaw_180_offset_label, wrapper_yaw_180_offset_label)
items.yaw_180_offset = config_system.push(
'Builder', hash 'yaw_180_offset', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Offset', hash 'yaw_180_offset'), -180, 180, 0, true, '°'
)
)
local wrapper_yaw_random_label = theme_controller.wrap(new_key('Randomization ${•}', hash 'yaw_random'))
items.yaw_random_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_random_label()
)
theme_controller.push(items.yaw_random_label, wrapper_yaw_random_label)
items.yaw_random = config_system.push(
'Builder', hash 'yaw_random', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Randomization', hash 'yaw_random'), 0, 30, 0, true, '%'
)
)
end
local yaw_lr do
local yaw_side do
local wrapper_yaw_side_label = theme_controller.wrap(new_key('Side ${»}', hash 'yaw_side'))
items.yaw_side_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_side_label()
)
theme_controller.push(items.yaw_side_label, wrapper_yaw_side_label)
items.yaw_side = config_system.push(
'Builder', hash 'yaw_side', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Side', hash 'yaw_side'), {
'Left',
'Right',
}
)
)
end

local left_yaw do
-- Keep the Left/Right yaw offsets in the normal GameSense flow.  Native
-- side-by-side anchoring was unstable when conditional Builder rows rebuilt,
-- so the two controls are intentionally stacked: Right first, Left second.
-- Each slider keeps only its own label directly above it.
local wrapper_yaw_right_offset_label = theme_controller.wrap(new_key('Right offset ${•}', hash 'yaw_right_offset'))
items.yaw_right_offset_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_right_offset_label()
)
theme_controller.push(items.yaw_right_offset_label, wrapper_yaw_right_offset_label)
items.yaw_right_offset = config_system.push(
'Builder', hash 'yaw_right_offset', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Right offset', hash 'yaw_right_offset'), -180, 180, 0, true, '°'
)
)

local wrapper_yaw_left_offset_label = theme_controller.wrap(new_key('Left offset ${•}', hash 'yaw_left_offset'))
items.yaw_left_offset_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_left_offset_label()
)
theme_controller.push(items.yaw_left_offset_label, wrapper_yaw_left_offset_label)
items.yaw_left_offset = config_system.push(
'Builder', hash 'yaw_left_offset', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Left offset', hash 'yaw_left_offset'), -180, 180, 0, true, '°'
)
)
items.yaw_left_delay = { }
do
local hash_label = hash('yaw_left_label_1')
local hash_delay = hash('yaw_left_delay_1')
local wrapper_label = theme_controller.wrap(new_key('Delay [1] ${•}', hash_label))
local item_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_label()
)
local item_delay = config_system.push(
'Builder', hash_delay, menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Delay', hash_delay), 1, 14, 2, true, 't'
)
)
theme_controller.push(item_label, wrapper_label)
items.yaw_left_delay[1] = { label = item_label, delay = item_delay }
end
end
items.yaw_right_delay = { }
-- Keep Delay [2] in the normal GameSense vertical flow.  The previous
-- side-by-side native anchoring was rebuilt by conditional Builder rows and
-- could leave this slider detached at the bottom of the page (next to Send).
-- A normal label + slider pair is deterministic across state/mode changes.
if not is_freestanding then
local hash_right_label = hash('yaw_right_label_1')
local hash_right_delay = hash('yaw_right_delay_1')
local wrapper_right_delay = theme_controller.wrap(new_key('Delay [2] ${•}', hash_right_label))
local right_delay_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_right_delay()
)
theme_controller.push(right_delay_label, wrapper_right_delay)
local right_delay_slider = config_system.push(
'Builder', hash_right_delay, menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Delay', hash_right_delay), 1, 14, 4, true, 't'
)
)
items.yaw_right_delay[1] = { label = right_delay_label, delay = right_delay_slider }
end
end
local wrapper_yaw_delay_mode_label = theme_controller.wrap(new_key('⤿ Delay mode ${»}', hash 'yaw_delay_mode'))
items.yaw_delay_mode_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_delay_mode_label()
)
theme_controller.push(items.yaw_delay_mode_label, wrapper_yaw_delay_mode_label)
items.yaw_delay_mode = config_system.push(
'Builder', hash 'yaw_delay_mode', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Delay mode', hash 'yaw_delay_mode'), {
'Default',
'Randomized',
'Alternating',
'Smart',
'Record Phase',
'Flick',
'Custom'
}
)
)
local wrapper_yaw_custom_mode_label = theme_controller.wrap(new_key('Custom delay mode ${»}', hash 'yaw_custom_mode'))
items.yaw_custom_mode_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_custom_mode_label()
)
theme_controller.push(items.yaw_custom_mode_label, wrapper_yaw_custom_mode_label)
items.yaw_custom_mode = config_system.push(
'Builder', hash 'yaw_custom_mode', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Custom delay mode', hash 'yaw_custom_mode'), {
'Sequential',
'Smart Random',
'Random'
}
)
)
local wrapper_yaw_custom_count_label = theme_controller.wrap(new_key('Custom delay count ${•}', hash 'yaw_custom_count'))
items.yaw_custom_count_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_custom_count_label()
)
theme_controller.push(items.yaw_custom_count_label, wrapper_yaw_custom_count_label)
items.yaw_custom_count = config_system.push(
'Builder', hash 'yaw_custom_count', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Custom delay count', hash 'yaw_custom_count'), 1, 12, 1, true
)
)
items.yaw_custom_delays = { }
for i = 1, 12 do
local hash_label = hash(string.format('yaw_custom_delay_label_%s', i))
local hash_delay = hash(string.format('yaw_custom_delay_%s', i))
local wrapper_label = theme_controller.wrap(new_key(string.format('Custom delay %d ${•}', i), hash_label))
local item_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_label()
)
local item_delay = config_system.push(
'Builder', hash_delay, menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Custom delay', hash_delay), 1, 32, 1, true, 'ms', 1, {
[1] = 'Gamesense'
}
)
)
theme_controller.push(item_label, wrapper_label)
items.yaw_custom_delays[i] = {
label = item_label,
delay = item_delay
}
end
items.yaw_custom_randomize = menu.new(
ui.new_button, 'AA', 'Anti-aimbot angles', 'Randomize', function()
for i = 1, 12 do
local entry = items.yaw_custom_delays[i]
if entry ~= nil then entry.delay:set(utils.random_int(1, 32)) end
end
end
)
items.separator = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', hash 'yaw')
)
local yaw_jitter do
local jitter_option do
local wrapper_yaw_jitter_label = theme_controller.wrap(new_key('⤿ Yaw jitter ${»}', hash 'yaw_jitter'))
items.yaw_jitter_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_jitter_label()
)
theme_controller.push(items.yaw_jitter_label, wrapper_yaw_jitter_label)
items.yaw_jitter = config_system.push(
'Builder', hash 'yaw_jitter', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Yaw jitter', hash 'yaw_jitter'), {
'Off',
'Offset',
'Center',
'Random',
'Record Phase'
}
)
)
end
local jitter_x_yaw do
local wrapper_jitter_x_way_label = theme_controller.wrap(new_key('Mode ${»}', hash 'jitter_x_way'))
items.jitter_x_way_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_jitter_x_way_label()
)
theme_controller.push(items.jitter_x_way_label, wrapper_jitter_x_way_label)
items.jitter_x_way = config_system.push(
'Builder', hash 'jitter_x_way', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Mode', hash 'jitter_x_way'), {
'Auto',
'Custom',
}
)
)
local wrapper_x_way_ways_label = theme_controller.wrap(new_key('Ways ${•}', hash 'x_way_offset'))
items.x_way_ways_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_ways_label()
)
theme_controller.push(items.x_way_ways_label, wrapper_x_way_ways_label)
items.x_way_ways = config_system.push(
'Builder', hash 'x_way_ways', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Ways', hash 'x_way_offset'), 3, 5, 3, true, 'w'
)
)
local wrapper_x_way_offset_1_label = theme_controller.wrap(new_key('First Offset ${•}', hash 'x_way_offset_1_label'))
items.x_way_offset_1_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_1_label()
)
theme_controller.push(items.x_way_offset_1_label, wrapper_x_way_offset_1_label)
items.x_way_offset_1 = config_system.push(
'Builder', hash 'x_way_offset_1', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n First Offset', hash 'x_way_offset_1'), -180, 180, 0, true, '°'
)
)
local wrapper_x_way_offset_2_label = theme_controller.wrap(new_key('Second Offset ${•}', hash 'x_way_offset_2_label'))
items.x_way_offset_2_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_2_label()
)
theme_controller.push(items.x_way_offset_2_label, wrapper_x_way_offset_2_label)
items.x_way_offset_2 = config_system.push(
'Builder', hash 'x_way_offset_2', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Second Offset', hash 'x_way_offset_2'), -180, 180, 0, true, '°'
)
)
local wrapper_x_way_offset_3_label = theme_controller.wrap(new_key('Third Offset ${•}', hash 'x_way_offset_3_label'))
items.x_way_offset_3_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_3_label()
)
theme_controller.push(items.x_way_offset_3_label, wrapper_x_way_offset_3_label)
items.x_way_offset_3 = config_system.push(
'Builder', hash 'x_way_offset_3', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Third Offset', hash 'x_way_offset_3'), -180, 180, 0, true, '°'
)
)
local wrapper_x_way_offset_4_label = theme_controller.wrap(new_key('Fourth Offset ${•}', hash 'x_way_offset_4_label'))
items.x_way_offset_4_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_4_label()
)
theme_controller.push(items.x_way_offset_4_label, wrapper_x_way_offset_4_label)
items.x_way_offset_4 = config_system.push(
'Builder', hash 'x_way_offset_4', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Fourth Offset', hash 'x_way_offset_4'), -180, 180, 0, true, '°'
)
)
local wrapper_x_way_offset_5_label = theme_controller.wrap(new_key('Fifth Offset ${•}', hash 'x_way_offset_5_label'))
items.x_way_offset_5_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_5_label()
)
theme_controller.push(items.x_way_offset_5_label, wrapper_x_way_offset_5_label)
items.x_way_offset_5 = config_system.push(
'Builder', hash 'x_way_offset_5', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Fifth Offset', hash 'x_way_offset_5'), -180, 180, 0, true, '°'
)
)
end
local jitter_offset do
local wrapper_jitter_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'jitter_offset'))
items.jitter_offset_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_jitter_offset_label()
)
theme_controller.push(items.jitter_offset_label, wrapper_jitter_offset_label)
items.jitter_offset = config_system.push(
'Builder', hash 'jitter_offset', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Offset', hash 'jitter_offset'), -180, 180, 0, true, '°'
)
)
end
local jitter_random do
local wrapper_jitter_random_label = theme_controller.wrap(new_key('Randomization ${•}', hash 'jitter_random'))
items.jitter_random_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_jitter_random_label()
)
theme_controller.push(items.jitter_random_label, wrapper_jitter_random_label)
items.jitter_random = config_system.push(
'Builder', hash 'jitter_random', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Randomization', hash 'jitter_random'), 0, 30, 0, true, '%'
)
)
end
end
items.separator2 = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator2', hash 'jitter')
)
end

if is_freestanding then
local wrapper_yaw_jitter_label = theme_controller.wrap(new_key('⤿ Yaw jitter ${»}', hash 'yaw_jitter'))
items.yaw_jitter_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_jitter_label()
)
theme_controller.push(items.yaw_jitter_label, wrapper_yaw_jitter_label)
items.yaw_jitter = config_system.push(
'Builder', hash 'yaw_jitter', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Yaw jitter', hash 'yaw_jitter'), {
'Off',
'Offset',
'Center',
'Random',
'Record Phase'
}
)
)
local wrapper_jitter_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'jitter_offset'))
items.jitter_offset_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_jitter_offset_label()
)
theme_controller.push(items.jitter_offset_label, wrapper_jitter_offset_label)
items.jitter_offset = config_system.push(
'Builder', hash 'jitter_offset', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Offset', hash 'jitter_offset'), -180, 180, 0, true, '°'
)
)
local wrapper_jitter_random_label = theme_controller.wrap(new_key('Randomization ${•}', hash 'jitter_random'))
items.jitter_random_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_jitter_random_label()
)
theme_controller.push(items.jitter_random_label, wrapper_jitter_random_label)
items.jitter_random = config_system.push(
'Builder', hash 'jitter_random', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Randomization', hash 'jitter_random'), 0, 30, 0, true, '%'
)
)
end

local wrapper_body_yaw_label = theme_controller.wrap(new_key('⤿ Body yaw ${»}', hash 'angel_body_yaw'))
items.body_yaw_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_yaw_label()
)
theme_controller.push(items.body_yaw_label, wrapper_body_yaw_label)

items.body_yaw = config_system.push(
'Builder', hash 'angel_body_yaw', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles',
new_key('\n Body yaw', hash 'angel_body_yaw'), {
'Off',
'Static',
'Jitter',
'Random',
'Min/Max'
}
)
)

local wrapper_body_yaw_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'angel_body_yaw_offset'))
items.body_yaw_offset_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_yaw_offset_label()
)
theme_controller.push(items.body_yaw_offset_label, wrapper_body_yaw_offset_label)
items.body_yaw_offset = config_system.push(
'Builder', hash 'angel_body_yaw_offset', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('\n Offset', hash 'angel_body_yaw_offset'),
-180, 180, 0, true, '°'
)
)

local wrapper_body_yaw_min_label = theme_controller.wrap(new_key('Minimum offset ${•}', hash 'angel_body_yaw_min'))
items.body_yaw_offset_min_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_yaw_min_label()
)
theme_controller.push(items.body_yaw_offset_min_label, wrapper_body_yaw_min_label)
items.body_yaw_offset_min = config_system.push(
'Builder', hash 'angel_body_yaw_min', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('\n Minimum offset', hash 'angel_body_yaw_min'),
-180, 180, 0, true, '°'
)
)

local wrapper_body_yaw_max_label = theme_controller.wrap(new_key('Maximum offset ${•}', hash 'angel_body_yaw_max'))
items.body_yaw_offset_max_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_yaw_max_label()
)
theme_controller.push(items.body_yaw_offset_max_label, wrapper_body_yaw_max_label)
items.body_yaw_offset_max = config_system.push(
'Builder', hash 'angel_body_yaw_max', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('\n Maximum offset', hash 'angel_body_yaw_max'),
-180, 180, 0, true, '°'
)
)

items.freestanding_body_yaw = config_system.push(
'Builder', hash 'angel_freestanding_body_yaw', menu.new(
ui.new_checkbox, 'AA', 'Anti-aimbot angles',
new_key('Freestanding body yaw', hash 'angel_freestanding_body_yaw')
)
)

local wrapper_body_delay_mode_label = theme_controller.wrap(new_key('Delay mode ${»}', hash 'angel_body_delay_mode'))
items.body_delay_mode_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_delay_mode_label()
)
theme_controller.push(items.body_delay_mode_label, wrapper_body_delay_mode_label)
items.body_delay_mode = config_system.push(
'Builder', hash 'angel_body_delay_mode', menu.new(
ui.new_combobox, 'AA', 'Anti-aimbot angles',
new_key('\n Delay mode', hash 'angel_body_delay_mode'), {
'Default',
'Custom'
}
)
)

local wrapper_body_delay_count_label = theme_controller.wrap(new_key('Delay count ${•}', hash 'angel_body_delay_count'))
items.body_delay_count_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_delay_count_label()
)
theme_controller.push(items.body_delay_count_label, wrapper_body_delay_count_label)
items.body_delay_count = config_system.push(
'Builder', hash 'angel_body_delay_count', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('\n Delay count', hash 'angel_body_delay_count'),
2, 10, 2, true
)
)

items.body_delays = { }
for i = 1, 10 do
local delay_hash = hash('angel_body_delay_' .. i)
local delay_wrapper = theme_controller.wrap(
new_key(string.format('Delay %d ${•}', i), delay_hash)
)
local delay_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', delay_wrapper()
)
theme_controller.push(delay_label, delay_wrapper)
local delay_item = config_system.push(
'Builder', delay_hash, menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('\n Delay', delay_hash),
1, 14, 1, true, 't'
)
)
items.body_delays[i] = {
label = delay_label,
delay = delay_item
}
end

local wrapper_invert_chance_label = theme_controller.wrap(new_key('Invert chance ${•}', hash 'angel_body_invert_chance'))
items.body_invert_chance_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_invert_chance_label()
)
theme_controller.push(items.body_invert_chance_label, wrapper_invert_chance_label)
items.body_invert_chance = config_system.push(
'Builder', hash 'angel_body_invert_chance', menu.new(
ui.new_slider, 'AA', 'Anti-aimbot angles',
new_key('\n Invert chance', hash 'angel_body_invert_chance'),
1, 100, 100, true, '%'
)
)

return items
end
local function pretty_builder_state_name(state)
local map = {
['Shared'] = 'Global',
['Slow Walk'] = 'Walking',
['Crouching'] = 'Duck',
['Crouching & Move'] = 'Duck Move',
['Air & Crouched'] = 'Air Duck',
['Legit AA'] = 'Legit'
}
return map[state] or state
end
local function builder_team_key(value)
return (value == 'Counter-Terrorist' or value == 'CT') and 'CT' or 'T'
end
local function get_builder_header()
local state_name = pretty_builder_state_name(current_state)
if current_state == 'Freestanding' then
return string.format(
'Customize  \a%s~\a%s  %s',
lock_clr(), reference.get_color(true), state_name
)
end
return string.format(
'Customize  \a%s~\a%s  %s  \a%s·\a%s  %s',
lock_clr(), reference.get_color(true), state_name,
lock_clr(), reference.get_color(true), active_builder_team
)
end
local header = theme_controller.wrap(new_key('Customize condition', 'builder_header'))
builder.state_label = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', header()
)
theme_controller.push(builder.state_label, header)
-- Keep the editor selectors in their own stable native row. Rebinding them
-- to conditionally hidden Builder controls breaks GameSense menu layout.
builder.state = aetheryx_native_inline.create(
{ track_only = true },
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n', 'builder_condition'), conditions
)
builder.team = aetheryx_native_inline.create(
{ w = 58, h = 18, x = 245, anchor_item = builder.state, same_line = true },
ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n', 'builder_team'), {
'T',
'CT'
}
)

local builder_editor_state_key = '##AETHERYX_BUILDER_EDITOR_VIEW_V1'
do
local saved_editor = database.read(builder_editor_state_key)
if type(saved_editor) == 'table' then
    local saved_state = tostring(saved_editor.state or '')
    for i = 1, #conditions do
        if conditions[i] == saved_state then
            pcall(builder.state.set, builder.state, saved_state)
            break
        end
    end
    local saved_team = saved_editor.team == 'CT' and 'CT' or 'T'
    pcall(builder.team.set, builder.team, saved_team)
end
end

builder.separator = menu.new(
ui.new_label, 'AA', 'Anti-aimbot angles', new_key(' ', 'builder_top_separator')
)
builder.physical = {
angles = create_builder_items('UI'),
anti_bruteforce = create_anti_bruteforce_items('UI'),
defensive = create_defensive_items('UI'),
}

-- Standard full-width buttons are created after every Builder control, so
-- native visibility flow keeps them at the actual bottom.
builder.send_to_ct = menu.new(
ui.new_button, 'AA', 'Anti-aimbot angles', 'Send to CT', function()
if send_builder_to_team ~= nil then send_builder_to_team('CT') end
end
)
builder.send_to_t = menu.new(
ui.new_button, 'AA', 'Anti-aimbot angles', 'Send to T', function()
if send_builder_to_team ~= nil then send_builder_to_team('T') end
end
)

send_builder_to_team = function(target)
local state = builder.state:get()
local source = active_builder_team
if target == source then return end

local slot = builder_bank_slot(target, state)
for item, suffix in pairs(rawget(_G, '__aetheryx_ui_item_suffix')) do
slot[suffix] = { item:get() }
end

builder_bank_dirty = true
client.log(
"[aetheryx] builder " .. tostring(state) ..
" sent: " .. tostring(source) .. " -> " .. tostring(target)
)
end

VIRTUAL_ITEM_MODE = true
for i = 1, #conditions do
local state = conditions[i]
CURRENT_VIRTUAL_STATE = state
local items = { }
items.angles = create_builder_items(state, nil)
items.anti_bruteforce = create_anti_bruteforce_items(state)
items.defensive = create_defensive_items(state)
builder[state] = items
end
CURRENT_VIRTUAL_STATE = nil
VIRTUAL_ITEM_MODE = false

local builder_bank_key = '##AETHERYX_BUILDER_BANK_V1'
do
local saved_bank = database.read(builder_bank_key)
if type(saved_bank) == 'table' then
builder_value_bank = saved_bank
if prune_removed_builder_fields(builder_value_bank) then builder_bank_dirty=true end
end
end
local builder_bank_last_save = 0
local builder_syncing = false
local function copy_bank_node(value)
return clone_builder_value(value)
end

local function ensure_freestanding_common_bank()
builder_value_bank.BOTH = builder_value_bank.BOTH or { }

if builder_value_bank.BOTH.Freestanding == nil then
local source =
(builder_value_bank.T and builder_value_bank.T.Freestanding)
or (builder_value_bank.CT and builder_value_bank.CT.Freestanding)
or { }

builder_value_bank.BOTH.Freestanding =
copy_bank_node(source)

builder_bank_dirty = true
end
end

ensure_freestanding_common_bank()

local function ensure_team_bank(key)
if builder_value_bank[key] ~= nil then return end
local other = key == 'T' and 'CT' or 'T'
builder_value_bank[key] = copy_bank_node(builder_value_bank[other] or { })
end
local function refresh_builder_header()
current_state = builder.state:get()
builder.state_label:set(get_builder_header())
end
sync_physical_from_bank = function()
builder_syncing = true
local state = builder.state:get()
local profile_team = builder_editor_profile_team(state)
local team_bank = builder_value_bank[profile_team]
local state_bank = team_bank ~= nil and team_bank[state] or nil
for item, suffix in pairs(rawget(_G, '__aetheryx_ui_item_suffix')) do
local vals = state_bank ~= nil and state_bank[suffix] or nil
if vals == nil then vals = item.default end
if vals ~= nil then pcall(item.set, item, unpack(vals)) end
end
builder_syncing = false
builder_synced_version = builder_bank_version
end
for item, suffix in pairs(rawget(_G, '__aetheryx_ui_item_suffix')) do
item:set_callback(function(it)
if builder_syncing then return end
local state = builder.state:get()
local profile_team = builder_editor_profile_team(state)
builder_bank_slot(profile_team, state)[suffix] = { it:get() }
builder_bank_dirty = true
end)
end
local function flush_physical_to_bank(team, state)
if state == nil then return end
local profile_team = state == 'Freestanding' and 'BOTH' or team
local slot = builder_bank_slot(profile_team, state)
for item, suffix in pairs(rawget(_G, '__aetheryx_ui_item_suffix')) do
slot[suffix] = { item:get() }
end
builder_bank_version = builder_bank_version + 1
builder_bank_dirty = true
end
local function save_builder_editor_view()
database.write(builder_editor_state_key, {
state = builder.state:get(),
team = builder.team:get()
})
end
local function switch_builder_team(item)
local next_key = builder_team_key(item:get())
if next_key ~= active_builder_team then
flush_physical_to_bank(active_builder_team, builder.state:get())
ensure_team_bank(next_key)
active_builder_team = next_key
end
save_builder_editor_view()
sync_physical_from_bank()
refresh_builder_header()
menu_logic.animate_next()
end
local builder_editor_initialized = false
builder.state:set_callback(function()
-- current_state still contains the previous editor state here. Do not flush
-- on the initial force-callback, otherwise defaults would overwrite the
-- database bank before its first sync.
if builder_editor_initialized then
flush_physical_to_bank(active_builder_team, current_state)
end
save_builder_editor_view()
sync_physical_from_bank()
refresh_builder_header()
builder_editor_initialized = true
menu_logic.animate_next()
end, true)
builder.team:set_callback(switch_builder_team, true)
function builder:switch_team_profile(value)
local key = builder_team_key(value)
local ui_value = key == 'CT' and 'CT' or 'T'
if self.team:get() ~= ui_value then self.team:set(ui_value) end
switch_builder_team(self.team)
end
__aetheryx_runtime.set('paint_ui', function()
if builder_bank_dirty and globals.realtime() - builder_bank_last_save >= 0.5 then
builder_bank_last_save = globals.realtime()
builder_bank_dirty = false
database.write(builder_bank_key, builder_value_bank)
end
end)
__aetheryx_runtime.set('shutdown', function() database.write(builder_bank_key, builder_value_bank) end)
sync_physical_from_bank()
refresh_builder_header()
end
local features = { } do
antiaim.features = features
local avoid_backstab = { } do
features.avoid_backstab = avoid_backstab
avoid_backstab.checkbox = config_system.push(
'Features', 'avoid_backstab.enabled', menu.new(
ui.new_checkbox, 'AA', 'Other', new_key('Avoid backstab', 'avoid_backstab')
)
)
avoid_backstab.distance = config_system.push(
'Features', 'avoid_backstab.distance', menu.new(
ui.new_slider, 'AA', 'Other', new_key('↪ Distance', 'avoid_backstab'), 150, 320, 240, true, 'u'
)
)
avoid_backstab.separator = menu.new(
ui.new_label, 'AA', 'Other', new_key('\n Separator', 'avoid_backstab')
)
end
features.fast_ladder = config_system.push(
'Features', 'fast_ladder.aetheryx', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Fast ladder', 'fast_ladder_aetheryx')
)
)
local manual_yaw = { } do
features.manual_yaw = manual_yaw
manual_yaw.checkbox = config_system.push(
'Features', 'manual_yaw.checkbox', menu.new(
ui.new_checkbox, 'AA', 'Other', new_key('Manual Yaw', 'manual_yaw_checkbox')
)
)
local wrapper_forward_label = theme_controller.wrap(new_key('Forward  ${}', 'manual_yaw_forward_label'))
manual_yaw.forward_label = menu.new(
ui.new_label, 'AA', 'Other', wrapper_forward_label()
)
theme_controller.push(manual_yaw.forward_label, wrapper_forward_label)
manual_yaw.forward = config_system.push(
'Features', 'manual_yaw.forward', menu.new(
ui.new_hotkey, 'AA', 'Other', new_key('Forward', 'manual_yaw_forward_hotkey'), true
)
)
local wrapper_left_label = theme_controller.wrap(new_key('Left  ${}', 'manual_yaw_left_label'))
manual_yaw.left_label = menu.new(
ui.new_label, 'AA', 'Other', wrapper_left_label()
)
theme_controller.push(manual_yaw.left_label, wrapper_left_label)
manual_yaw.left = config_system.push(
'Features', 'manual_yaw.left', menu.new(
ui.new_hotkey, 'AA', 'Other', new_key('Left', 'manual_yaw_left_hotkey'), true
)
)
manual_yaw.left:set 'Toggle'
local wrapper_right_label = theme_controller.wrap(new_key('Right  ${}', 'manual_yaw_right_label'))
manual_yaw.right_label = menu.new(
ui.new_label, 'AA', 'Other', wrapper_right_label()
)
theme_controller.push(manual_yaw.right_label, wrapper_right_label)
manual_yaw.right = config_system.push(
'Features', 'manual_yaw.right', menu.new(
ui.new_hotkey, 'AA', 'Other', new_key('Right', 'manual_yaw_right_hotkey'), true
)
)
manual_yaw.right:set 'Toggle'
manual_yaw.arrows_title = menu.new(
ui.new_label, 'AA', 'Other',
new_key(polished_title('‹›', 'ARROWS', 'MANUAL YAW'), 'manual_arrows_title')
)
manual_yaw.arrows = config_system.push(
'Features', 'manual_yaw.arrows', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Manual Arrows', 'manual_arrows')
)
)
manual_yaw.freestanding_body = config_system.push(
'Features', 'manual_yaw.freestanding_body', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('Freestanding body', 'manual_yaw_freestanding_body')
)
)
manual_yaw.arrows_style = config_system.push(
'Features', 'manual_yaw.arrows_style', menu.new(
ui.new_combobox, 'AA', 'Other',
new_key('↪ Style', 'manual_arrows_style'), {
'Invictus',
'Modern',
'Ambani',
'Team Skeet'
}
)
)
manual_yaw.arrows_color = config_system.push(
'Features', 'manual_yaw.arrows_color', menu.new(
ui.new_color_picker, 'AA', 'Other',
new_key('\n Accent', 'manual_arrows'),
175, 255, 55, 255
)
)
manual_yaw.arrows_secondary = config_system.push(
'Features', 'manual_yaw.arrows_secondary', menu.new(
ui.new_color_picker, 'AA', 'Other',
new_key('\n Secondary', 'manual_arrows_secondary'),
255, 255, 255, 255
)
)
manual_yaw.arrows_offset = config_system.push(
'Features', 'manual_yaw.arrows_offset', menu.new(
ui.new_slider, 'AA', 'Other',
new_key('↪ Offset', 'manual_arrows_offset'),
5, 150, 40, true, 'px'
)
)
manual_yaw.arrows_animate_scope = config_system.push(
'Features', 'manual_yaw.arrows_animate_scope', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('↪ Animate scope', 'manual_arrows_animate_scope')
)
)
manual_yaw.arrows_dynamic = config_system.push(
'Features', 'manual_yaw.arrows_dynamic', menu.new(
ui.new_checkbox, 'AA', 'Other',
new_key('↪ Dynamic mode', 'manual_arrows_dynamic')
)
)
manual_yaw.arrows:set(true)
end
local freestanding = { } do
features.freestanding = freestanding
freestanding.checkbox = config_system.push(
'Features', 'freestanding.checkbox', menu.new(
ui.new_checkbox, 'AA', 'Fake lag', new_key('Freestanding', 'freestanding_checkbox')
)
)
freestanding.hotkey = config_system.push(
'Features', 'freestanding.hotkey', menu.new(
ui.new_hotkey, 'AA', 'Fake lag', new_key('↪ Activation Hotkey', 'freestanding_hotkey'), true
)
)
freestanding.disablers = config_system.push(
'Features', 'freestanding.disablers', menu.new(
ui.new_multiselect, 'AA', 'Fake lag', new_key('↪ Disablers', 'freestanding_disablers'), {
'Standing',
'Moving',
'Slow Walk',
'Crouching',
'Air'
}
)
)
end
local safe_head = { } do
features.safe_head = safe_head
safe_head.checkbox = config_system.push(
'Features', 'safe_head.checkbox', aetheryx_native_inline.create(
{ track_only = true },
ui.new_checkbox, 'AA', 'Fake lag', new_key('Safe Head', 'safe_head_checkbox')
)
)
safe_head.select = config_system.push(
'Features', 'safe_head.select', aetheryx_native_inline.create(
{ w = 108, h = 18, anchor_item = safe_head.checkbox, right_pad = 0, dx = 58 },
ui.new_multiselect, 'AA', 'Fake lag', new_key('\n Weapons', 'safe_head_select'), {
'Knife',
'Taser'
}
)
)
safe_head.select:set('Knife', 'Taser')
safe_head.helper = menu.new(
ui.new_label, 'AA', 'Fake lag', new_key('Static anti-aim while active', 'safe_head_helper')
)
safe_head.conditions = config_system.push(
'Features', 'safe_head.conditions', menu.new(
ui.new_multiselect, 'AA', 'Fake lag', new_key('↪ Conditions', 'safe_head_conditions'), {
'Standing',
'Crouch',
'Air crouch',
'Air crouch knife',
'Air crouch taser',
'Distance'
}
)
)
local wrapper_options_label = theme_controller.wrap(new_key('Options  ${~}', 'safe_head_options_label'))
safe_head.options_label = menu.new(
ui.new_label, 'AA', 'Fake lag', wrapper_options_label()
)
theme_controller.push(safe_head.options_label, wrapper_options_label)
safe_head.options = config_system.push(
'Features', 'safe_head.options', menu.new(
ui.new_multiselect, 'AA', 'Fake lag', new_key('↪ Options', 'safe_head_options'), {'E Spam while active'}
)
)
safe_head.mode = config_system.push(
'Features', 'safe_head.mode', menu.new(
ui.new_combobox, 'AA', 'Fake lag', new_key('↪ Mode', 'safe_head_mode'), {
'Standard', 'Aggressive'
}
)
)
safe_head.disablers = config_system.push(
'Features', 'safe_head.disablers', menu.new(
ui.new_multiselect, 'AA', 'Fake lag', new_key('↪ Disable on', 'safe_head_disablers'), {
'Manual active',
'Freestanding active'
}
)
)
end
end
end
local scene do
local function set_antiaimbot_display(value)
local items = reference.antiaim.angles
local pitch_value = ui.get(items.pitch[1])
local yaw_value = ui.get(items.yaw[1])
local body_yaw_value = ui.get(items.body_yaw[1])
local force = not value
ui.set_visible(items.enabled, value)
ui.set_visible(items.pitch[1], value)
if pitch_value == 'Custom' or force then
ui.set_visible(items.pitch[2], value)
end
ui.set_visible(items.yaw_base, value)
ui.set_visible(items.yaw[1], value)
if yaw_value ~= 'Off' or force then
local yaw_jitter_value = ui.get(items.yaw_jitter[1])
ui.set_visible(items.yaw[2], value)
ui.set_visible(items.yaw_jitter[1], value)
if yaw_jitter_value ~= 'Off' or force then
ui.set_visible(items.yaw_jitter[2], value)
end
end
ui.set_visible(items.body_yaw[1], value)
if body_yaw_value ~= 'Off' or force then
if body_yaw_value ~= 'Opposite' or force then
ui.set_visible(items.body_yaw[2], value)
end
ui.set_visible(items.freestanding_body_yaw, value)
end
ui.set_visible(items.edge_yaw, value)
ui.set_visible(items.freestanding[1], value)
ui.set_visible(items.freestanding[2], value)
ui.set_visible(items.roll, value)
end
local function set_fakelag_display(value)
local items = reference.antiaim.fake_lag
ui.set_visible(items.enabled[1], value)
ui.set_visible(items.enabled[2], value)
ui.set_visible(items.amount, value)
ui.set_visible(items.limit, value)
ui.set_visible(items.variance, value)
end
local function set_other_display(value)
local items = reference.antiaim.other
ui.set_visible(items.slow_motion[1], value)
ui.set_visible(items.slow_motion[2], value)
ui.set_visible(items.leg_movement, value)
ui.set_visible(items.on_shot_antiaim[1], value)
ui.set_visible(items.on_shot_antiaim[2], value)
ui.set_visible(items.fake_peek[1], value)
ui.set_visible(items.fake_peek[2], value)
end
local function update_builder_items(items, edit_state)
local angles = items.angles
local anti_bruteforce = items.anti_bruteforce
local defensive = items.defensive
if angles ~= nil then
if edit_state ~= 'Shared' and angles.enabled ~= nil then
menu_logic.set(angles.enabled, true)
if not angles.enabled:get() then
return
end
end
if edit_state == 'Legit AA' and angles.bomb_e_fix ~= nil then
menu_logic.set(angles.bomb_e_fix, true)
end
if edit_state ~= 'Freestanding' then
if angles.pitch_type ~= nil then
menu_logic.set(angles.pitch_type, true)
end
if angles.yaw_type_label ~= nil then
menu_logic.set(angles.yaw_base_label, true)
end
if angles.yaw_type ~= nil then
menu_logic.set(angles.yaw_base, true)
menu_logic.set(angles.yaw_type_label, true)
menu_logic.set(angles.yaw_type, true)
if angles.yaw_type:get() == '180' then
menu_logic.set(angles.yaw_180_offset_label, true)
menu_logic.set(angles.yaw_180_offset, true)
menu_logic.set(angles.yaw_random_label, true)
menu_logic.set(angles.yaw_random, true)
menu_logic.set(angles.separator, true)
end
if angles.yaw_type:get() == 'Between' then
menu_logic.set(angles.yaw_between_global_label, true)
menu_logic.set(angles.yaw_between_global, true)
menu_logic.set(angles.yaw_between_hold_label, true)
menu_logic.set(angles.yaw_between_hold, true)
menu_logic.set(angles.yaw_between_switch_label, true)
menu_logic.set(angles.yaw_between_switch, true)
menu_logic.set(angles.yaw_between_offset_label, true)
menu_logic.set(angles.yaw_between_offset, true)
menu_logic.set(angles.separator, true)
end
if angles.yaw_type:get() == 'Left / Right' then
menu_logic.set(angles.separator, true)
menu_logic.set(angles.yaw_left_offset_label, true)
menu_logic.set(angles.yaw_left_offset, true)
menu_logic.set(angles.yaw_right_offset_label, true)
menu_logic.set(angles.yaw_right_offset, true)
menu_logic.set(angles.yaw_delay_mode_label, true)
menu_logic.set(angles.yaw_delay_mode, true)
local delay_mode = angles.yaw_delay_mode:get()
local left_delay = angles.yaw_left_delay and angles.yaw_left_delay[1]
local right_delay = angles.yaw_right_delay and angles.yaw_right_delay[1]
if left_delay ~= nil and delay_mode ~= 'Custom' and delay_mode ~= 'Record Phase' then
menu_logic.set(left_delay.label, true)
menu_logic.set(left_delay.delay, true)
end
if right_delay ~= nil and delay_mode ~= 'Default' and delay_mode ~= 'Flick'
and delay_mode ~= 'Custom' and delay_mode ~= 'Record Phase' then
menu_logic.set(right_delay.label, true)
menu_logic.set(right_delay.delay, true)
end
if delay_mode == 'Custom' then
menu_logic.set(angles.yaw_custom_mode_label, true)
menu_logic.set(angles.yaw_custom_mode, true)
menu_logic.set(angles.yaw_custom_count_label, true)
menu_logic.set(angles.yaw_custom_count, true)
local custom_count = math.max(1, math.min(12, angles.yaw_custom_count:get() or 1))
for i = 1, 12 do
local entry = angles.yaw_custom_delays and angles.yaw_custom_delays[i]
if entry ~= nil and i <= custom_count then
menu_logic.set(entry.label, true)
menu_logic.set(entry.delay, true)
end
end
menu_logic.set(angles.yaw_custom_randomize, true)
end
end
end
if angles.yaw_jitter ~= nil then
menu_logic.set(angles.yaw_jitter_label, true)
menu_logic.set(angles.yaw_jitter, true)
if angles.yaw_jitter:get() ~= 'Off' then
menu_logic.set(angles.jitter_offset_label, true)
menu_logic.set(angles.jitter_offset, true)
menu_logic.set(angles.separator2, true)
end
end
end
if angles.body_yaw ~= nil then
menu_logic.set(angles.body_yaw_label, true)
menu_logic.set(angles.body_yaw, true)

local body_yaw_mode = angles.body_yaw:get()

if body_yaw_mode ~= 'Off' then
if body_yaw_mode == 'Min/Max' then
menu_logic.set(angles.body_yaw_offset_min_label, true)
menu_logic.set(angles.body_yaw_offset_min, true)
menu_logic.set(angles.body_yaw_offset_max_label, true)
menu_logic.set(angles.body_yaw_offset_max, true)
else
menu_logic.set(angles.body_yaw_offset_label, true)
menu_logic.set(angles.body_yaw_offset, true)
end

if body_yaw_mode == 'Static' then
menu_logic.set(angles.freestanding_body_yaw, true)
else
menu_logic.set(angles.body_delay_mode_label, true)
menu_logic.set(angles.body_delay_mode, true)
menu_logic.set(angles.body_invert_chance_label, true)
menu_logic.set(angles.body_invert_chance, true)

local delay_mode = angles.body_delay_mode:get()
if delay_mode == 'Custom' then
menu_logic.set(angles.body_delay_count_label, true)
menu_logic.set(angles.body_delay_count, true)
local count = math.max(2, math.min(10, angles.body_delay_count:get() or 2))
for i = 1, 10 do
local entry = angles.body_delays and angles.body_delays[i]
if entry ~= nil and i <= count then
menu_logic.set(entry.label, true)
menu_logic.set(entry.delay, true)
end
end
else
for i = 1, 2 do
local entry = angles.body_delays and angles.body_delays[i]
if entry ~= nil then
menu_logic.set(entry.label, true)
menu_logic.set(entry.delay, true)
end
end
end
end
end
end
if angles.yaw_modifier_enabled ~= nil then
menu_logic.set(angles.yaw_modifier_label, true)
menu_logic.set(angles.yaw_modifier_enabled, true)
if angles.yaw_modifier_enabled:get() then
menu_logic.set(angles.yaw_modifier_mode, true)
menu_logic.set(angles.yaw_modifier_values_mode, true)
menu_logic.set(angles.yaw_modifier_variability, true)
menu_logic.set(angles.yaw_modifier_speed, true)
local values_mode = angles.yaw_modifier_values_mode:get()
if values_mode == 'Custom' then
menu_logic.set(angles.yaw_modifier_sliders, true)
local count = angles.yaw_modifier_sliders:get()
for i = 1, count do
menu_logic.set(angles['yaw_modifier_slot_' .. i], true)
end
elseif values_mode == 'Switch' then
menu_logic.set(angles.yaw_modifier_slot_1, true)
menu_logic.set(angles.yaw_modifier_slot_2, true)
else
menu_logic.set(angles.yaw_modifier_slot_1, true)
end
end
end
if angles.hidden_yaw_enabled ~= nil then
menu_logic.set(angles.hidden_yaw_enabled, true)
if angles.hidden_yaw_enabled:get() then
menu_logic.set(angles.hidden_yaw_mode, true)
local hidden_mode = angles.hidden_yaw_mode:get()
if hidden_mode == 'Static' then
menu_logic.set(angles.hidden_yaw_static, true)
else
menu_logic.set(angles.hidden_yaw_left, true)
menu_logic.set(angles.hidden_yaw_right, true)
end
menu_logic.set(angles.hidden_yaw_modifier_enabled, true)
if angles.hidden_yaw_modifier_enabled:get() then
menu_logic.set(angles.hidden_yaw_modifier_mode, true)
menu_logic.set(angles.hidden_yaw_modifier_variability, true)
menu_logic.set(angles.hidden_yaw_modifier_speed, true)
for i = 1, 5 do
menu_logic.set(angles['hidden_yaw_modifier_slot_' .. i], true)
end
end
end
end
end
if anti_bruteforce ~= nil then
menu_logic.set(anti_bruteforce.checkbox, true)
if anti_bruteforce.checkbox:get() then
menu_logic.set(anti_bruteforce.refresh_modifier, true)
menu_logic.set(anti_bruteforce.refresh_offset, true)
menu_logic.set(anti_bruteforce.enforce_delay, true)
menu_logic.set(anti_bruteforce.duration, true)
menu_logic.set(anti_bruteforce.memory_enabled,true)
menu_logic.set(anti_bruteforce.memory_radius,true)
if anti_bruteforce.memory_enabled:get() then
menu_logic.set(anti_bruteforce.memory_decay,true)
menu_logic.set(anti_bruteforce.memory_rhythm,true)
menu_logic.set(anti_bruteforce.memory_log,true)
end
end
end
if defensive ~= nil then
menu_logic.set(defensive.enabled, true)

if defensive.enabled:get() then
menu_logic.set(defensive.force_break_lc, true)
menu_logic.set(defensive.pitch, true)

local pitch = defensive.pitch:get()
if pitch ~= 'Off' and pitch ~= 'Angelic' then
menu_logic.set(defensive.pitch_offset_1, true)
if pitch ~= 'Static' then
menu_logic.set(defensive.pitch_label_1, true)
menu_logic.set(defensive.pitch_label_2, true)
menu_logic.set(defensive.pitch_offset_2, true)
end
if pitch == 'Spin' then
menu_logic.set(defensive.pitch_speed, true)
end
end

menu_logic.set(defensive.yaw, true)
local yaw = defensive.yaw:get()
if yaw ~= 'Off' then
if yaw == 'Left/Right' or yaw == 'Side-based' then
menu_logic.set(defensive.yaw_left, true)
menu_logic.set(defensive.yaw_right, true)
if yaw == 'Side-based' then
menu_logic.set(defensive.yaw_offset, true)
end
else
menu_logic.set(defensive.yaw_offset, true)
end

if yaw == 'Spin' then
menu_logic.set(defensive.yaw_speed, true)
end

menu_logic.set(defensive.yaw_modifier, true)
if defensive.yaw_modifier:get() ~= 'Off' then
menu_logic.set(defensive.modifier_offset, true)
end

menu_logic.set(defensive.delay, true)
if defensive.delay:get() then
menu_logic.set(defensive.delays[1], true)
menu_logic.set(defensive.delays[2], true)
menu_logic.set(defensive.delay_affect_modifier, true)
end

menu_logic.set(defensive.force_target_yaw, true)
end
end
end

end
local function force_update_scene()
local category = category_selector.current()
local home_other = other.selector.tab:get()
local home_antiaim = antiaim.selector.tab:get()
-- The main workspace selector is always visible. The smaller Builder/Features
-- selector is only exposed while the Anti-aimbot angles workspace is active.
menu_logic.set(category_selector.brand, true)
menu_logic.set(category_selector.categories, true)

-- Force Shot lives directly in native Rage -> Aimbot and is independent from
-- the Aetheryx workspace selector. One bind/value is shared by every weapon.
local fs = other.force_shot
if fs ~= nil then
menu_logic.set(fs.checkbox, true)
if fs.checkbox:get() then
menu_logic.set(fs.minimum_hitchance, true)
menu_logic.set(fs.hotkey, true)
menu_logic.set(fs.on_ground, true)
end
end
if category == 'config' then
local ref = home.config_local
menu_logic.set(ref.config_title, true)
menu_logic.set(ref.list, true)
menu_logic.set(ref.input, true)
menu_logic.set(ref.load, true)
menu_logic.set(ref.save, true)
menu_logic.set(ref.delete, true)
menu_logic.set(ref.import, true)
menu_logic.set(ref.export, true)
end
if category == 'misc' then
local ref = other.selector
menu_logic.set(ref.brand,true)

-- Compact layout: no Settings/Type combobox, only section headers.
menu_logic.set(other.visual.section_header,true)
menu_logic.set(other.visual.section_separator,true)
menu_logic.set(other.aimbot_helper.section_header,true)
menu_logic.set(other.aimbot_helper.section_separator,true)
menu_logic.set(other.miscellaneous.section_header,true)
menu_logic.set(other.miscellaneous.section_separator,true)

-- Left: Visuals.
local v = other.visual
menu_logic.set(v.min_damage_indicator,true)
if v.min_damage_indicator:get() then menu_logic.set(v.min_damage_color,true) end
menu_logic.set(v.event_logs,true)
if v.event_logs:get() then
menu_logic.set(v.event_log_show_screen,true)
if v.event_log_show_screen:get() then
menu_logic.set(v.event_log_text_color,true)
menu_logic.set(v.event_log_style,true)
end
end
menu_logic.set(v.animated_zoom,true)
if v.animated_zoom:get() then
menu_logic.set(v.animated_zoom_amount,true)
menu_logic.set(v.animated_zoom_speed,true)
end
menu_logic.set(v.center_indicators,true)
if v.center_indicators:get() then
menu_logic.set(v.center_indicator_style,true)
-- Position is controlled by the vertical Evalate-style drag rail.
local indicator_style = v.center_indicator_style:get()
if indicator_style == 'Stars' or indicator_style == 'Aetheryx' or indicator_style == 'Renewed' then
menu_logic.set(v.center_indicator_color_1,true)
menu_logic.set(v.center_indicator_color_2,true)
end
end

menu_logic.set(v.glass_hud,true)
if v.glass_hud:get() then
menu_logic.set(v.glass_hud_elements,true)
end

local m = other.miscellaneous
menu_logic.set(m.bullet_tracer.checkbox,true)
if m.bullet_tracer.checkbox:get() then menu_logic.set(m.bullet_tracer.color,true) end
menu_logic.set(m.plus_hitmarker.checkbox,true)

-- Right/top: Ragebot.
local ah = other.aimbot_helper
local lagrecord = other.lagrecord_update
if lagrecord ~= nil then
menu_logic.set(lagrecord.enabled, true)
if lagrecord.enabled:get() then
menu_logic.set(lagrecord.method, true)
menu_logic.set(lagrecord.validate_records, true)
if lagrecord.validate_records:get() then
menu_logic.set(lagrecord.max_record_age, true)
menu_logic.set(lagrecord.reject_teleport, true)
if lagrecord.reject_teleport:get() then
menu_logic.set(lagrecord.teleport_distance, true)
end
end
end
end
menu_logic.set(ah.checkbox,true)
if ah.checkbox:get() then
menu_logic.set(ah.weapons,true)
menu_logic.set(ah.miss_reasons,true)
menu_logic.set(ah.miss_decay,true)
menu_logic.set(ah.lethal_margin,true)
local items = ah[ah.weapons:get()]
if items ~= nil then
menu_logic.set(items.options,true)
if items.options:get('Force safe point') then
menu_logic.set(items.force_safe_point.triggers,true)
if items.force_safe_point.triggers:get('Enemy HP < X') then menu_logic.set(items.force_safe_point.hp,true) end
if items.force_safe_point.triggers:get('X missed shots') then menu_logic.set(items.force_safe_point.missed_shots,true) end
end
if items.options:get('Prefer body aim') then
menu_logic.set(items.prefer_body_aim.triggers,true)
if items.prefer_body_aim.triggers:get('Enemy HP < X') then menu_logic.set(items.prefer_body_aim.hp,true) end
if items.prefer_body_aim.triggers:get('X missed shots') then menu_logic.set(items.prefer_body_aim.missed_shots,true) end
end
if items.options:get('Force body aim') then
menu_logic.set(items.force_body_aim.triggers,true)
if items.force_body_aim.triggers:get('Enemy HP < X') then menu_logic.set(items.force_body_aim.hp,true) end
if items.force_body_aim.triggers:get('X missed shots') then menu_logic.set(items.force_body_aim.missed_shots,true) end
end
if items.options:get('Ping spike') then menu_logic.set(items.ping_spike.value,true) end
end
end

-- Right/bottom: Miscellaneous.
menu_logic.set(m.console_filter,true)
menu_logic.set(m.viewmodel.checkbox,true)
if m.viewmodel.checkbox:get() then
menu_logic.set(m.viewmodel.fov,true)
menu_logic.set(m.viewmodel.offset_x,true)
menu_logic.set(m.viewmodel.offset_y,true)
menu_logic.set(m.viewmodel.offset_z,true)
menu_logic.set(m.viewmodel.options,true)
menu_logic.set(m.viewmodel.reset,true)
end
menu_logic.set(m.hitrate.checkbox,true)
if m.hitrate.checkbox:get() then menu_logic.set(m.hitrate.reset,true) end
menu_logic.set(m.aspect_ratio.checkbox,true)
if m.aspect_ratio.checkbox:get() then menu_logic.set(m.aspect_ratio.value,true) end
menu_logic.set(m.remove_sleeves.checkbox,true)
menu_logic.set(m.game_enhancer.checkbox,true)
if m.game_enhancer.checkbox:get() then
menu_logic.set(m.game_enhancer.list,true)
menu_logic.set(m.game_enhancer.separator,true)
end
menu_logic.set(m.animation_breaker.checkbox,true)
if m.animation_breaker.checkbox:get() then
menu_logic.set(m.animation_breaker.triggers,true)
if m.animation_breaker.triggers:get('Air') then
menu_logic.set(m.animation_breaker.air_mode,true)
if m.animation_breaker.air_mode:get()=='Static' then menu_logic.set(m.animation_breaker.air_amount,true) end
end
if m.animation_breaker.triggers:get('Ground') then
menu_logic.set(m.animation_breaker.ground_mode,true)
if m.animation_breaker.ground_mode:get()=='Jitter' then menu_logic.set(m.animation_breaker.ground_amount,true) end
end
if m.animation_breaker.triggers:get('Tweaks') then
menu_logic.set(m.animation_breaker.tweaks,true)
if m.animation_breaker.tweaks:get('Body Lean') then menu_logic.set(m.animation_breaker.tweaks_amount,true) end
end
end
end
if category == 'anti-aim' then
local selector_ref = antiaim.selector
menu_logic.set(selector_ref.brand, false)
menu_logic.set(selector_ref.tab, true)
if home_antiaim == 'builder' then
local ref = antiaim.builder
local state = ref.state:get()
local is_freestanding_state = state == 'Freestanding'

menu_logic.set(ref.state, true)
if not is_freestanding_state and ref.team ~= nil then
menu_logic.set(ref.team, true)
end

if builder_bank_version ~= builder_synced_version then
sync_physical_from_bank()
end

update_builder_items(ref.physical, state)

if not is_freestanding_state then
if active_builder_team == 'T' then
menu_logic.set(ref.send_to_ct, true)
else
menu_logic.set(ref.send_to_t, true)
end
end
end
if home_antiaim == 'settings' then
local ref = antiaim.features
local is_avoid_backstab = ref.avoid_backstab.checkbox:get()
menu_logic.set(ref.avoid_backstab.checkbox, true)
if is_avoid_backstab then
menu_logic.set(ref.avoid_backstab.distance, true)
menu_logic.set(ref.avoid_backstab.separator, true)
end
menu_logic.set(ref.fast_ladder, true)
local is_safe_head = ref.safe_head.checkbox:get()
menu_logic.set(ref.safe_head.checkbox, true)
if is_safe_head then
menu_logic.set(ref.safe_head.select, true)
menu_logic.set(ref.safe_head.helper, true)
end
local is_manual_yaw = ref.manual_yaw.checkbox:get()
menu_logic.set(ref.manual_yaw.checkbox, true)
if is_manual_yaw then
menu_logic.set(ref.manual_yaw.forward_label, true)
menu_logic.set(ref.manual_yaw.forward, true)
menu_logic.set(ref.manual_yaw.left_label, true)
menu_logic.set(ref.manual_yaw.left, true)
menu_logic.set(ref.manual_yaw.right_label, true)
menu_logic.set(ref.manual_yaw.right, true)
menu_logic.set(ref.manual_yaw.freestanding_body, true)
menu_logic.set(ref.manual_yaw.arrows_title, true)
menu_logic.set(ref.manual_yaw.arrows, true)
if ref.manual_yaw.arrows:get() then
menu_logic.set(ref.manual_yaw.arrows_style, true)

-- Manual arrows keep Accent.
menu_logic.set(ref.manual_yaw.arrows_color, true)

menu_logic.set(ref.manual_yaw.arrows_secondary, true)
menu_logic.set(ref.manual_yaw.arrows_offset, true)
menu_logic.set(ref.manual_yaw.arrows_animate_scope, true)
local arrow_style = ref.manual_yaw.arrows_style:get()
if arrow_style == 'Invictus' or arrow_style == 'Ambani' then
menu_logic.set(ref.manual_yaw.arrows_dynamic, true)
end
end
end
local is_freestanding = ref.freestanding.checkbox:get()
menu_logic.set(ref.freestanding.checkbox, true)
if is_freestanding then
menu_logic.set(ref.freestanding.hotkey, true)
menu_logic.set(ref.freestanding.disablers, true)
end

end
end
end
local angel_preset_bank = { }
angel_preset_bank['Shared'] = {
['enabled'] = { true },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { 'Left / Right' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 19 },
['yaw_left_offset'] = { -15 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Center' },
['jitter_offset'] = { 28 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Off' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Off' },
['defensive_yaw_offset'] = { 0 },
['defensive_yaw_left'] = { 0 },
['defensive_yaw_right'] = { 0 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
angel_preset_bank['Standing'] = {
['enabled'] = { true },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { 'Left / Right' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 19 },
['yaw_left_offset'] = { -15 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Center' },
['jitter_offset'] = { 28 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Off' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Off' },
['defensive_yaw_offset'] = { 0 },
['defensive_yaw_left'] = { 0 },
['defensive_yaw_right'] = { 0 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
angel_preset_bank['Moving'] = {
['enabled'] = { true },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { 'Left / Right' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 21 },
['yaw_left_offset'] = { -18 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Center' },
['jitter_offset'] = { 42 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Off' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Off' },
['defensive_yaw_offset'] = { 0 },
['defensive_yaw_left'] = { 0 },
['defensive_yaw_right'] = { 0 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
angel_preset_bank['Slow Walk'] = {
['enabled'] = { true },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { 'Left / Right' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 0 },
['yaw_left_offset'] = { 0 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Center' },
['jitter_offset'] = { 79 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Off' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Off' },
['defensive_yaw_offset'] = { 0 },
['defensive_yaw_left'] = { 0 },
['defensive_yaw_right'] = { 0 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
angel_preset_bank['Crouching'] = {
['enabled'] = { true },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { 'Left / Right' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 16 },
['yaw_left_offset'] = { -8 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Center' },
['jitter_offset'] = { 54 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Static' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Sway' },
['defensive_yaw_offset'] = { -41 },
['defensive_yaw_left'] = { 11 },
['defensive_yaw_right'] = { -6 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
angel_preset_bank['Crouching & Move'] = {
['enabled'] = { true },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { 'Left / Right' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 8 },
['yaw_left_offset'] = { -14 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Center' },
['jitter_offset'] = { 31 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Static' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'X-Way' },
['defensive_yaw_offset'] = { 0 },
['defensive_yaw_left'] = { 48 },
['defensive_yaw_right'] = { -17 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 4 },
['defensive_delay_to'] = { 4 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
angel_preset_bank['Air'] = {
['enabled'] = { true },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { 'Left / Right' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 16 },
['yaw_left_offset'] = { -12 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Center' },
['jitter_offset'] = { 40 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Static' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Sway' },
['defensive_yaw_offset'] = { -37 },
['defensive_yaw_left'] = { 13 },
['defensive_yaw_right'] = { -13 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
angel_preset_bank['Air & Crouched'] = {
['enabled'] = { true },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { 'Left / Right' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 14 },
['yaw_left_offset'] = { -3 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Center' },
['jitter_offset'] = { 31 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Static' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Sway' },
['defensive_yaw_offset'] = { -38 },
['defensive_yaw_left'] = { 12 },
['defensive_yaw_right'] = { -12 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
angel_preset_bank['Freestanding'] = {
['enabled'] = { false },
['yaw_base'] = { 'At targets' },
['yaw_type'] = { '180' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 0 },
['yaw_left_offset'] = { 0 },
['yaw_left_delay_1'] = { 6 },
['yaw_right_delay_1'] = { 6 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Off' },
['jitter_offset'] = { 0 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Jitter' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Static' },
['defensive_pitch_offset_1'] = { 0 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Left/Right' },
['defensive_yaw_offset'] = { 0 },
['defensive_yaw_left'] = { 0 },
['defensive_yaw_right'] = { 0 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 6 },
['angel_body_delay_2'] = { 6 },
['angel_body_delay_3'] = { 6 },
['angel_body_delay_4'] = { 6 },
['angel_body_delay_5'] = { 6 },
['angel_body_delay_6'] = { 6 },
['angel_body_delay_7'] = { 6 },
['angel_body_delay_8'] = { 6 },
['angel_body_delay_9'] = { 6 },
['angel_body_delay_10'] = { 6 }
}
angel_preset_bank['Legit AA'] = {
['enabled'] = { false },
['yaw_base'] = { 'Local view' },
['yaw_type'] = { '180' },
['yaw_180_offset'] = { 0 },
['yaw_random'] = { 0 },
['yaw_side'] = { 'Right' },
['yaw_right_offset'] = { 0 },
['yaw_left_offset'] = { 0 },
['yaw_left_delay_1'] = { 1 },
['yaw_right_delay_1'] = { 1 },
['yaw_delay_mode'] = { 'Default' },
['yaw_custom_mode'] = { 'Sequential' },
['yaw_custom_count'] = { 1 },
['yaw_jitter'] = { 'Off' },
['jitter_offset'] = { 0 },
['jitter_random'] = { 0 },
['angel_body_yaw'] = { 'Off' },
['angel_body_yaw_offset'] = { 60 },
['angel_body_yaw_min'] = { -60 },
['angel_body_yaw_max'] = { 60 },
['angel_freestanding_body_yaw'] = { false },
['angel_body_delay_mode'] = { 'Default' },
['angel_body_delay_count'] = { 2 },
['angel_body_invert_chance'] = { 100 },
['defensive_enabled'] = { false },
['defensive_type'] = { 'Default' },
['defensive_pitch'] = { 'Off' },
['defensive_pitch_offset_1'] = { 89 },
['defensive_pitch_offset_2'] = { 0 },
['defensive_pitch_speed'] = { 20 },
['defensive_yaw'] = { 'Off' },
['defensive_yaw_offset'] = { 0 },
['defensive_yaw_left'] = { 0 },
['defensive_yaw_right'] = { 0 },
['defensive_yaw_speed'] = { 20 },
['defensive_ways_count'] = { 3 },
['defensive_ways_custom'] = { false },
['defensive_ways_auto_body_yaw'] = { false },
['defensive_flick_yaw_offset'] = { 90 },
['defensive_body_yaw'] = { 'Off' },
['defensive_body_yaw_offset'] = { 58 },
['defensive_freestanding_body_yaw'] = { false },
['defensive_delay_from'] = { 1 },
['defensive_delay_to'] = { 1 },
['aetheryx_antibrute_enabled'] = { true },
['aetheryx_antibrute_refresh_modifier'] = { 'Decrease' },
['aetheryx_antibrute_refresh_offset'] = { true },
['aetheryx_antibrute_enforce_delay'] = { true },
['aetheryx_antibrute_duration'] = { 27 },
['yaw_custom_delay_1'] = { 1 },
['yaw_custom_delay_2'] = { 1 },
['yaw_custom_delay_3'] = { 1 },
['yaw_custom_delay_4'] = { 1 },
['yaw_custom_delay_5'] = { 1 },
['yaw_custom_delay_6'] = { 1 },
['yaw_custom_delay_7'] = { 1 },
['yaw_custom_delay_8'] = { 1 },
['yaw_custom_delay_9'] = { 1 },
['yaw_custom_delay_10'] = { 1 },
['yaw_custom_delay_11'] = { 1 },
['yaw_custom_delay_12'] = { 1 },
['angel_body_delay_1'] = { 1 },
['angel_body_delay_2'] = { 1 },
['angel_body_delay_3'] = { 1 },
['angel_body_delay_4'] = { 1 },
['angel_body_delay_5'] = { 1 },
['angel_body_delay_6'] = { 1 },
['angel_body_delay_7'] = { 1 },
['angel_body_delay_8'] = { 1 },
['angel_body_delay_9'] = { 1 },
['angel_body_delay_10'] = { 1 }
}
local angel_preset_key = '##AETHERYX_ANGELWINGS_DEFAULTS_V2'
local function assign_builder_defaults(node, values, seen)
if type(node) ~= 'table' then return end
seen = seen or { }
if seen[node] then return end
seen[node] = true
if node.is_virtual and node.__vsuffix ~= nil then
local value = values[node.__vsuffix]
if value ~= nil then node.default = clone_builder_value(value) end
return
end
for _, child in pairs(node) do
if type(child) == 'table' then assign_builder_defaults(child, values, seen) end
end
end
local function preset_default(item, ...)
if item ~= nil then item.default = { ... } end
end
for state, values in pairs(angel_preset_bank) do
assign_builder_defaults(menu_elements.antiaim.builder[state], values)
if state == 'Freestanding' then
builder_value_bank.BOTH = builder_value_bank.BOTH or { }
builder_value_bank.BOTH[state] = builder_value_bank.BOTH[state] or clone_builder_value(values)
else
builder_value_bank.T = builder_value_bank.T or { }
builder_value_bank.CT = builder_value_bank.CT or { }
builder_value_bank.T[state] = builder_value_bank.T[state] or clone_builder_value(values)
builder_value_bank.CT[state] = builder_value_bank.CT[state] or clone_builder_value(values)
end
end
local default_features = menu_elements.antiaim.features
preset_default(default_features.avoid_backstab.checkbox, true)
preset_default(default_features.avoid_backstab.distance, 240)
preset_default(default_features.fast_ladder, true)
preset_default(default_features.manual_yaw.checkbox, true)
preset_default(default_features.manual_yaw.arrows, true)
preset_default(default_features.manual_yaw.arrows_style, 'Invictus')
preset_default(default_features.manual_yaw.arrows_color, 172, 167, 209, 255)
preset_default(default_features.manual_yaw.arrows_secondary, 255, 255, 255, 255)
preset_default(default_features.manual_yaw.arrows_offset, 40)
preset_default(default_features.manual_yaw.arrows_animate_scope, true)
preset_default(default_features.manual_yaw.arrows_dynamic, true)
preset_default(default_features.freestanding.checkbox, true)
preset_default(default_features.freestanding.hotkey, 'On hotkey', 18)
preset_default(default_features.safe_head.checkbox, false)
local default_visual = menu_elements.other.visual
preset_default(default_visual.min_damage_indicator, true)
preset_default(default_visual.event_logs, true)
preset_default(default_visual.event_log_show_screen, true)
preset_default(default_visual.center_indicators, true)
preset_default(default_visual.center_indicator_style, 'Stars')
local default_misc = menu_elements.other.miscellaneous
preset_default(default_misc.console_filter, false)
preset_default(default_misc.animation_breaker.checkbox, true)
preset_default(default_misc.animation_breaker.triggers, 'Air', 'Ground')
preset_default(default_misc.animation_breaker.air_mode, 'Static')
preset_default(default_misc.animation_breaker.ground_mode, 'Static')
if database.read(angel_preset_key) ~= true then
for state, values in pairs(angel_preset_bank) do
if state == 'Freestanding' then
builder_value_bank.BOTH = builder_value_bank.BOTH or { }
builder_value_bank.BOTH[state] = clone_builder_value(values)
else
builder_value_bank.T = builder_value_bank.T or { }
builder_value_bank.CT = builder_value_bank.CT or { }
builder_value_bank.T[state] = clone_builder_value(values)
builder_value_bank.CT[state] = clone_builder_value(values)
end
end
local function preset_set(item, ...)
if item ~= nil then pcall(item.set, item, ...) end
end
local features = menu_elements.antiaim.features
preset_set(features.avoid_backstab.checkbox, true)
preset_set(features.avoid_backstab.distance, 240)
preset_set(features.fast_ladder, true)
preset_set(features.manual_yaw.checkbox, true)
preset_set(features.manual_yaw.arrows, true)
preset_set(features.manual_yaw.arrows_style, 'Invictus')
preset_set(features.manual_yaw.arrows_color, 172, 167, 209, 255)
preset_set(features.manual_yaw.arrows_secondary, 255, 255, 255, 255)
preset_set(features.manual_yaw.arrows_offset, 40)
preset_set(features.manual_yaw.arrows_animate_scope, true)
preset_set(features.manual_yaw.arrows_dynamic, true)
preset_set(features.freestanding.checkbox, true)
preset_set(features.freestanding.hotkey, 'On hotkey', 18)
preset_set(features.safe_head.checkbox, false)
local visual = menu_elements.other.visual
preset_set(visual.min_damage_indicator, true)
preset_set(visual.event_logs, true)
preset_set(visual.event_log_show_screen, true)
preset_set(visual.center_indicators, true)
preset_set(visual.center_indicator_style, 'Stars')
local misc = menu_elements.other.miscellaneous
preset_set(misc.console_filter, false)
preset_set(misc.animation_breaker.checkbox, true)
preset_set(misc.animation_breaker.triggers, 'Air', 'Ground')
preset_set(misc.animation_breaker.air_mode, 'Static')
preset_set(misc.animation_breaker.ground_mode, 'Static')
builder_bank_version = builder_bank_version + 1
builder_bank_dirty = true
database.write('##AETHERYX_BUILDER_BANK_V1', builder_value_bank)
database.write(angel_preset_key, true)
if sync_physical_from_bank ~= nil then sync_physical_from_bank() end
menu_logic.force_update()
end

local native_controls_hidden = false
local function set_native_controls_hidden(hidden)
if native_controls_hidden == hidden then return end
set_antiaimbot_display(not hidden)
set_fakelag_display(not hidden)
set_other_display(not hidden)
native_controls_hidden = hidden
end
local function on_shutdown()
set_native_controls_hidden(false)
end
local function force_hide_native_angle_controls()
local angles=reference.antiaim.angles
local native_items={
angles.enabled,
angles.pitch[1],angles.pitch[2],
angles.yaw_base,
angles.yaw[1],angles.yaw[2],
angles.yaw_jitter[1],angles.yaw_jitter[2],
angles.body_yaw[1],angles.body_yaw[2],
angles.freestanding_body_yaw,
angles.edge_yaw,
angles.freestanding[1],angles.freestanding[2],
angles.roll
}
for i=1,#native_items do
if native_items[i]~=nil then pcall(ui.set_visible,native_items[i],false) end
end
end
local function on_paint_ui()
local menu_open = ui.is_menu_open()
set_native_controls_hidden(menu_open)
if menu_open then force_hide_native_angle_controls() end
end
local logic_events = menu_logic.get_event_bus() do
logic_events.update:set(force_update_scene)
force_update_scene()
menu_logic.force_update()
end
local feature_master_state = { }
local feature_master_items = {
menu_elements.antiaim.features.manual_yaw.checkbox,
menu_elements.antiaim.features.freestanding.checkbox,
menu_elements.antiaim.features.safe_head.checkbox
}
local function poll_feature_master_changes()
if not ui.is_menu_open() then return end
local masters = feature_master_items
for i = 1, #masters do
local item = masters[i]
local ok, value = pcall(ui.get, item.ref)
value = ok and value == true or false
if feature_master_state[item.ref] == nil then
feature_master_state[item.ref] = value
elseif feature_master_state[item.ref] ~= value then
feature_master_state[item.ref] = value
menu_logic.animate_next()
end
end
end
__aetheryx_runtime.set('shutdown', on_shutdown)
__aetheryx_runtime.set('paint_ui', on_paint_ui)
__aetheryx_runtime.set('paint_ui', poll_feature_master_changes)

end
end
local aetheryx_ports = { } do
local visual = menu_elements.other.visual
local function clamp(value, minimum, maximum)
return math.max(minimum, math.min(maximum, value))
end
local function approach(current, target, speed)
current = tonumber(current) or 0
target = tonumber(target) or current
local factor = math.min(math.max(tonumber(globals.frametime()) or 0, 0) * (tonumber(speed) or 1), 1)
return current + (target - current) * factor
end
local function safe_get(item, fallback)
if item == nil then
return fallback
end
local ok, value = pcall(ui.get, item)
if not ok then
return fallback
end
return value
end
local function is_alive(me)
return me ~= nil and me ~= 0 and entity.is_alive(me)
end
local function is_fake_duck_active()
return safe_get(reference.ragebot.other.duck_peek_assist, false) == true
end
local force_shot_indicator_active = false
local indicator_state = {
alive = 0,
scoped = 0,
dt = 0,
hs = 0,
duck = 0,
baim = 0,
safe = 0,
fs = 0,
shot = 0,
damage = 0,
}
local state_names = {
Shared = 'STAND',
Standing = 'STAND',
Moving = 'MOVE',
['Slow Walk'] = 'SLOW WALK',
Crouching = 'CROUCH',
['Crouching & Move'] = 'CROUCH MOVE',
Air = 'AIR',
['Air & Crouched'] = 'AIR CROUCH',
Freestanding = 'FREESTAND',
['Manual AA'] = 'MANUAL',
['Legit AA'] = 'LEGIT'
}
local text_height_cache = { }
local function cached_text_height(flags, text_value)
flags = flags or ''
text_value = tostring(text_value or '')
local key = flags .. '\0' .. text_value
local height = text_height_cache[key]
if height == nil then
local _, measured = renderer.measure_text(flags, text_value)
height = math.max(measured or 8, 8)
text_height_cache[key] = height
end
return height
end
local function centered_text(x, y, r, g, b, a, flags, text_value)
renderer.text(
math.floor(x), math.floor(y),
r, g, b, a,
(flags or '') .. 'c',
0,
text_value
)
return cached_text_height(flags, text_value)
end
local function indicator_core_state(me, preview)
local alive = is_alive(me)
local dt = preview or reference.is_double_tap_active()
local hs = not dt and (preview or reference.is_on_shot_antiaim_active())
local duck = preview or is_fake_duck_active()
local baim = preview or safe_get(
reference.ragebot.aimbot.force_body_aim,
false
) == true
local safe = preview or safe_get(
reference.ragebot.aimbot.force_safe_point,
false
) == true
local fs = preview or reference.is_freestanding()
local damage = preview or reference.is_override_minimum_damage()
local shot = preview or force_shot_indicator_active
local exp_data = exploit.get()
local def_data = exp_data and exp_data.defensive
local def_ticks = (def_data and def_data.left) or 0
local lc = preview or (exp_data and exp_data.breaking_lc)
local scoped = alive and entity.get_prop(me, 'm_bIsScoped') == 1 or false
indicator_state.alive = approach(indicator_state.alive, (alive or preview) and 1 or 0, 14)
indicator_state.scoped = approach(indicator_state.scoped, scoped and 1 or 0, 18)
indicator_state.dt = approach(indicator_state.dt, dt and 1 or 0, 18)
indicator_state.hs = approach(indicator_state.hs, hs and 1 or 0, 18)
indicator_state.duck = approach(indicator_state.duck, duck and 1 or 0, 18)
indicator_state.baim = approach(indicator_state.baim, baim and 1 or 0, 18)
indicator_state.safe = approach(indicator_state.safe, safe and 1 or 0, 18)
indicator_state.fs = approach(indicator_state.fs, fs and 1 or 0, 18)
indicator_state.shot = approach(indicator_state.shot, shot and 1 or 0, 18)
indicator_state.damage = approach(indicator_state.damage, damage and 1 or 0, 18)
indicator_state.lc = approach(indicator_state.lc, lc and 1 or 0, 18)
indicator_state.def = approach(indicator_state.def or 0, (preview or def_ticks > 0) and 1 or 0, 18)
local core = indicator_state.core
if core == nil then
core = { }
indicator_state.core = core
end
core.dt = dt
core.hs = hs
core.duck = duck
core.baim = baim
core.safe = safe
core.fs = fs
core.damage = damage
core.shot = shot
core.lc = lc
core.def_ticks = def_ticks
core.charged = preview or exploit.get().charged
core.manual = preview or aa_runtime_state.aa_owner == 'Manual'
core.state = preview and 'STAND'
or (state_names[conditions.get()[1]] or 'STAND')
return core
end
local indicator_rows = {
{label = 'DT', key = 'dt'},
{label = 'OS', key = 'hs'},
{label = 'DUCK', key = 'duck'},
{label = 'BAIM', key = 'baim'},
{label = 'SAFE', key = 'safe'},
{label = 'FS', key = 'fs'},
{label = 'SHOT', key = 'shot'},
{label = 'DEF', key = 'def'},
{label = 'LC', key = 'lc'},
}
local function render_japanese(x, y, alpha, core)
local manual = core.manual
local line_one = manual and 'リセット YAW' or 'てんしのような YAW'
local line_two = manual and 'デフォルト' or 'どうてきな'
local c1 = manual and {177, 151, 255} or {218, 118, 0}
local c2 = manual and {255, 0, 0} or {209, 139, 230}
y = y + centered_text(
x, y,
c1[1], c1[2], c1[3],
math.floor(255 * alpha),
'', line_one
)
y = y + centered_text(
x, y,
c2[1], c2[2], c2[3],
math.floor(255 * alpha),
'', line_two
)
if indicator_state.dt > 0.02 then
local text_value = is_fake_duck_active()
and '倍の (フェイクダック)'
or '倍の'
local charged = core.charged
y = y + centered_text(
x, y,
charged and 0 or 255,
charged and 255 or 0,
0,
math.floor(255 * alpha * indicator_state.dt),
'', text_value
)
elseif indicator_state.hs > 0.02 then
local fake_duck = is_fake_duck_active()
local text_value = fake_duck
and 'アンチエイム (フェイクダック)'
or 'アンチエイム'
y = y + centered_text(
x, y,
fake_duck and 255 or 209,
fake_duck and 0 or 139,
fake_duck and 0 or 230,
math.floor(255 * alpha * indicator_state.hs),
'', text_value
)
end
if indicator_state.damage > 0.02 then
local value = reference.is_override_minimum_damage()
and reference.get_override_damage()
or reference.get_minimum_damage()
y = y + centered_text(
x, y,
255, 255, 255,
math.floor(225 * alpha * indicator_state.damage),
'-', 'ダメージ ' .. tostring(value)
) - 1
end
end
local center_star_glyphs = {
{'✦', 0, 12, 0.50},
{'⋆', -6, 3, 0.20},
{'★', -1, 8, 0.40},
{'✨', -1, 6, 0.70},
{'⋆', -3, 4, 0.30},
{'★', -1, 7, 0.60},
{'⋆', -2, 5, 0.20},
{'✨', 0, 8, 0.70}
}
local function star_brand_gradient(text_value, r1, g1, b1, r2, g2, b2, a)
local out = { }
local now = globals.realtime()
local length = math.max(#text_value - 1, 1)
for i = 1, #text_value do
local phase = (i - 1) / length
local blend = (math.sin(now * 1.8 + phase * math.pi * 1.35) + 1) * 0.5
local rr = math.floor(r1 + (r2 - r1) * blend + 0.5)
local gg = math.floor(g1 + (g2 - g1) * blend + 0.5)
local bb = math.floor(b1 + (b2 - b1) * blend + 0.5)
out[#out + 1] = string.format('\a%02X%02X%02X%02X%s', rr, gg, bb, a, text_value:sub(i, i))
end
return table.concat(out)
end
-- AngelWings Stars data and layout, ported directly from its indicator block.
local angelwings_stars = {
{'✦', 0, 12, 0.5},
{'⋆', -6, 3, 0.2},
{'★', -1, 8, 0.4},
{'✨', -1, 6, 0.7},
{'⋆', -3, 4, 0.3},
{'★', -1, 7, 0.6},
{'⋆', -2, 5, 0.2},
{'✨', 0, 8, 0.7}
}
local function render_stars(x, y, alpha, core)
local ar, ag, ab, aa = visual.center_indicator_color_1:get()
local sr, sg, sb, sa = visual.center_indicator_color_2:get()
ar, ag, ab, aa = ar or 172, ag or 167, ab or 209, aa or 255
sr, sg, sb, sa = sr or 255, sg or 255, sb or 255, sa or 255
local scoped = indicator_state.scoped or 0
local dpi = reference.get_dpi()
if dpi == nil or dpi <= 0 then dpi = 1 end
x = x + math.floor(10 * scoped + 0.5)
local measured, total_width, max_height = {}, 0, 0
for i = 1, #angelwings_stars do
local star = angelwings_stars[i]
local width, height = renderer.measure_text('', star[1])
width, height = width or 0, height or 0
measured[i] = {width = width, height = height}
total_width = total_width + (width + star[2]) * dpi
max_height = math.max(max_height, height + star[3])
end
local draw_x = math.floor(x - total_width * 0.5 * (1 - scoped) + 0.5)
local realtime = globals.realtime()
for i = 1, #angelwings_stars do
local star = angelwings_stars[i]
local pulse = (math.sin(realtime * star[4]) * 0.5 + 0.5) * 0.7 + 0.3
renderer.text(draw_x + star[2], y + star[3], ar, ag, ab,
math.floor(aa * alpha * pulse), '', 0, star[1])
draw_x = draw_x + (measured[i].width + star[2]) * dpi
end
y = y + math.max(0, max_height) * 0.58 * dpi
local brand = 'aetheryx'
local brand_w, brand_h = renderer.measure_text('b', brand)
brand_w, brand_h = brand_w or 0, brand_h or 0
renderer.text(math.floor(x - brand_w * 0.5 * (1 - scoped) + 0.5), y,
ar, ag, ab, math.floor(aa * alpha), 'b', 0,
star_brand_gradient(brand, ar, ag, ab, sr, sg, sb, math.floor(math.min(aa, sa) * alpha)))
y = y + brand_h
local state_text = string.lower(tostring(core.state or ''))
local _, state_h = renderer.measure_text('', state_text)
renderer.text(math.floor(x - (renderer.measure_text('', state_text) or 0) * 0.5 * (1 - scoped) + 0.5), y,
255, 255, 255, math.floor(200 * alpha), '', 0, state_text)
y = y + (state_h or 0)
if indicator_state.dt > 0.02 then
local dr, dg, db, da = 255, 255, 255, 200
if reference.is_duck_peek_assist() then dr, dg, db, da = 255, 50, 0, 255 end
local tw, th = renderer.measure_text('', 'dt')
renderer.text(math.floor(x - (tw or 0) * 0.5 * (1 - scoped) + 0.5), y,
dr, dg, db, math.floor(da * indicator_state.dt * alpha), '', 0, 'dt')
y = y + math.floor((th or 0) * indicator_state.dt + 0.5)
end
if indicator_state.damage > 0.02 then
local tw, th = renderer.measure_text('', 'dmg')
renderer.text(math.floor(x - (tw or 0) * 0.5 * (1 - scoped) + 0.5), y,
255, 255, 255, math.floor(200 * indicator_state.damage * alpha), '', 0, 'dmg')
y = y + math.floor((th or 0) * indicator_state.damage + 0.5)
end
if indicator_state.hs > 0.02 then
local tw = renderer.measure_text('', 'osaa')
renderer.text(math.floor(x - (tw or 0) * 0.5 * (1 - scoped) + 0.5), y,
255, 255, 255, math.floor(200 * (1 - indicator_state.dt * 0.5) * indicator_state.hs * alpha), '', 0, 'osaa')
end
end

local function render_original(x, y, alpha, core)
local white_a = math.floor(255 * alpha)
local me = entity.get_local_player()
local team = entity.get_prop(me, 'm_iTeamNum') == 3 and 'ct' or 't'

renderer.text(x, y, 255, 255, 255, white_a, 'bc', 0, 'aetheryx')
y = y + 10
-- Emberlash uses round outer brackets and square team brackets.
renderer.text(x, y, 255, 255, 255, white_a, 'c', 0, '(preset [' .. team .. '])')
y = y + 10

-- Evalate/Emberlash-style charge test: DT is ready only after the command
-- clock has moved ahead of the local tickbase. During recharge show charging.
local tickbase = me ~= nil and entity.get_prop(me, 'm_nTickBase') or nil
local dt_active = reference.is_double_tap_active()
local dt_charged = tickbase ~= nil and globals.tickcount() > tickbase
if dt_active and not dt_charged then
renderer.text(x, y, 255, 255, 255, white_a, 'bc', 0, 'exploit \aFF455CFFcharging')
else
renderer.text(x, y, 255, 255, 255, white_a, 'bc', 0, 'exploit')
end
end
-- Small status glyphs use SVG textures too, matching the rendered/italic
-- Aetheryx wordmark instead of GameSense's normal or bold bitmap font.
local aetheryx_status_sources = {
['A'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.9615 8.5) scale(0.003524 -0.003524)"><path d="M875 576 786 1130 446 576ZM722 0 737 66Q768 69 809.5 74.5Q851 80 874 87Q905 97 920.5 108.0Q936 119 936 142Q936 150 924.0 240.0Q912 330 890 493H392Q359 441 322.0 372.5Q285 304 265 268Q247 236 230.5 196.5Q214 157 214 144Q214 111 267.0 91.0Q320 71 400 66L385 0H-160L-145 66Q-119 68 -77.5 77.5Q-36 87 -8 103Q27 123 59.5 152.5Q92 182 129 241Q302 515 508.5 851.0Q715 1187 872 1439H952L1141 210Q1147 173 1161.0 147.5Q1175 122 1203 100Q1223 86 1257.0 76.5Q1291 67 1317 66L1302 0Z" fill="white"/></g></svg>]===],
['B'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.7641 8.5) scale(0.003524 -0.003524)"><path d="M1181 1363Q1236 1333 1267.0 1283.5Q1298 1234 1298 1168Q1298 1077 1262.0 1008.0Q1226 939 1168 892Q1109 844 1034.5 812.5Q960 781 884 766V757Q942 750 1004.0 729.5Q1066 709 1116 675Q1169 640 1202.5 584.5Q1236 529 1236 453Q1236 340 1183.5 253.5Q1131 167 1051 113Q965 55 866.5 27.5Q768 0 664 0H-29L-13 66Q11 68 59.0 74.5Q107 81 128 90Q163 104 181.5 128.5Q200 153 208 188L445 1218Q447 1228 448.5 1237.5Q450 1247 450 1257Q450 1278 441.5 1293.5Q433 1309 412 1320Q383 1336 350.5 1343.5Q318 1351 290 1353L306 1419H932Q1003 1419 1064.5 1406.5Q1126 1394 1181 1363ZM969 902Q1016 957 1036.5 1018.5Q1057 1080 1057 1158Q1057 1211 1038.0 1248.0Q1019 1285 986 1307Q953 1328 913.0 1336.5Q873 1345 829 1345Q796 1345 755.5 1343.5Q715 1342 687 1341L560 789H685Q783 789 854.5 820.0Q926 851 969 902ZM904 216Q947 275 969.0 345.0Q991 415 991 483Q991 590 919.0 651.0Q847 712 717 712Q654 712 609.0 710.5Q564 709 541 708L428 219Q425 205 423.5 193.0Q422 181 422 170Q422 118 475.0 95.0Q528 72 610 72Q711 72 785.5 113.5Q860 155 904 216Z" fill="white"/></g></svg>]===],
['D'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.3818 8.5) scale(0.003524 -0.003524)"><path d="M1515 872Q1515 669 1436.0 503.5Q1357 338 1229 229Q1096 116 932.5 58.0Q769 0 590 0H-29L-14 66Q12 66 59.5 71.0Q107 76 127 84Q163 98 181.5 123.5Q200 149 207 184L443 1205Q446 1217 448.5 1231.5Q451 1246 451 1255Q451 1277 443.5 1293.5Q436 1310 413 1321Q387 1333 349.0 1341.5Q311 1350 291 1353L306 1419H907Q997 1419 1103.0 1393.5Q1209 1368 1301 1306Q1398 1241 1456.5 1132.5Q1515 1024 1515 872ZM1280 871Q1280 1095 1160.0 1219.0Q1040 1343 841 1343Q800 1343 756.0 1341.5Q712 1340 687 1339L433 238Q430 224 428.0 211.0Q426 198 426 186Q426 126 476.0 101.5Q526 77 640 77Q789 77 911.5 145.0Q1034 213 1115 326Q1198 443 1239.0 581.0Q1280 719 1280 871Z" fill="white"/></g></svg>]===],
['F'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.5879 8.5) scale(0.003524 -0.003524)"><path d="M1404 1419 1322 1064H1247Q1243 1171 1201.5 1249.5Q1160 1328 1100 1337Q1069 1341 1027.5 1343.0Q986 1345 932 1345H689L556 768H719Q777 768 825.0 780.5Q873 793 918 833Q941 854 969.5 901.0Q998 948 1015 1001H1091L963 444H887Q888 456 889.5 472.0Q891 488 891 507Q891 535 887.0 571.0Q883 607 872 625Q845 666 802.0 679.0Q759 692 700 692H537L423 195Q421 187 420.0 178.5Q419 170 419 162Q419 140 428.0 123.5Q437 107 459 94Q475 86 522.0 77.0Q569 68 599 66L583 0H-35L-19 66Q12 68 61.0 72.5Q110 77 128 84Q163 98 181.0 123.5Q199 149 207 184L446 1218Q448 1228 449.5 1237.5Q451 1247 451 1257Q451 1277 443.5 1291.5Q436 1306 412 1318Q390 1330 347.0 1340.0Q304 1350 275 1353L291 1419Z" fill="white"/></g></svg>]===],
['G'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.1880 8.5) scale(0.003524 -0.003524)"><path d="M667 -33Q547 -33 444.0 5.0Q341 43 264 117Q187 191 143.5 297.0Q100 403 100 540Q100 733 167.5 898.5Q235 1064 352 1188Q467 1311 624.0 1381.5Q781 1452 955 1452Q1093 1452 1191.5 1420.5Q1290 1389 1346 1351L1402 1419H1482L1377 923H1295Q1293 1006 1281.0 1086.0Q1269 1166 1231 1230Q1192 1295 1124.0 1333.0Q1056 1371 934 1371Q811 1371 701.5 1307.5Q592 1244 509 1129Q428 1018 381.5 862.0Q335 706 335 528Q335 306 440.0 178.0Q545 50 730 50Q818 50 883.0 76.0Q948 102 986 134Q1000 175 1012.5 220.5Q1025 266 1040 332L1059 418Q1061 429 1063.5 444.0Q1066 459 1066 472Q1066 497 1059.5 513.0Q1053 529 1028 540Q999 555 943.5 562.5Q888 570 858 572L873 640H1496L1481 572Q1455 569 1413.5 562.5Q1372 556 1344 544Q1308 528 1290.5 501.0Q1273 474 1264 437L1238 322Q1215 227 1206.0 180.0Q1197 133 1190 91Q1124 64 1072.5 44.0Q1021 24 944 5Q874 -13 809.5 -23.0Q745 -33 667 -33Z" fill="white"/></g></svg>]===],
['M'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(1.5960 8.5) scale(0.003524 -0.003524)"><path d="M2008 1419 1993 1353Q1964 1352 1919.0 1344.0Q1874 1336 1852 1329Q1813 1316 1796.0 1288.0Q1779 1260 1771 1228L1532 195Q1530 187 1529.0 177.0Q1528 167 1528 161Q1528 140 1537.0 123.5Q1546 107 1567 94Q1581 85 1626.5 76.0Q1672 67 1698 66L1682 0H1057L1073 66Q1109 68 1163.0 73.5Q1217 79 1239 90Q1274 109 1295.5 134.0Q1317 159 1324 195L1569 1252H1558L783 23H736L558 1277H548L347 405Q335 352 327.0 302.0Q319 252 319 221Q319 188 326.0 164.5Q333 141 346 126Q364 105 422.0 88.0Q480 71 513 66L497 0H-76L-60 66Q-13 71 34.0 80.0Q81 89 121 114Q161 141 189.0 202.0Q217 263 246 394L416 1130Q421 1153 423.5 1171.5Q426 1190 426 1208Q426 1240 418.0 1261.5Q410 1283 397 1298Q371 1327 326.5 1339.0Q282 1351 245 1353L260 1419H738L893 352L1445 1245Q1476 1296 1502.0 1350.0Q1528 1404 1532 1419Z" fill="white"/></g></svg>]===],
['O'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.2214 8.5) scale(0.003524 -0.003524)"><path d="M1477 873Q1477 683 1407.0 515.5Q1337 348 1224 229Q1108 107 959.5 36.5Q811 -34 652 -34Q404 -34 252.0 127.0Q100 288 100 540Q100 734 170.0 900.5Q240 1067 352 1188Q465 1311 615.5 1382.0Q766 1453 925 1453Q1169 1453 1323.0 1295.5Q1477 1138 1477 873ZM1095 339Q1166 463 1204.0 619.0Q1242 775 1242 931Q1242 1131 1157.0 1250.0Q1072 1369 907 1369Q779 1369 669.0 1293.0Q559 1217 477 1070Q406 941 370.5 786.0Q335 631 335 494Q335 284 421.5 167.0Q508 50 669 50Q806 50 915.0 132.0Q1024 214 1095 339Z" fill="white"/></g></svg>]===],
['P'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.7324 8.5) scale(0.003524 -0.003524)"><path d="M1312 1133Q1312 1012 1258.5 917.0Q1205 822 1121 759Q1033 693 924.0 659.5Q815 626 696 626H523L421 188Q419 179 418.0 169.0Q417 159 417 152Q417 130 425.0 113.0Q433 96 457 86Q472 79 517.5 73.0Q563 67 599 66L584 0H-25L-10 66Q15 68 61.0 73.0Q107 78 128 86Q164 100 182.5 126.5Q201 153 208 188L447 1222Q449 1231 450.5 1242.0Q452 1253 452 1263Q452 1284 444.0 1301.0Q436 1318 414 1327Q382 1339 346.0 1345.0Q310 1351 280 1353L295 1419H926Q1097 1419 1204.5 1342.5Q1312 1266 1312 1133ZM992 862Q1033 921 1050.0 987.5Q1067 1054 1067 1112Q1067 1158 1054.5 1199.0Q1042 1240 1012 1273Q982 1305 935.0 1323.5Q888 1342 817 1342H687L542 708H655Q771 708 855.0 746.5Q939 785 992 862Z" fill="white"/></g></svg>]===],
['S'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.9033 8.5) scale(0.003524 -0.003524)"><path d="M493 -29Q370 -29 277.5 1.5Q185 32 128 72L71 -1H-9L89 485H170Q175 398 193.5 322.0Q212 246 254 185Q296 122 363.0 87.5Q430 53 529 53Q678 53 768.0 135.5Q858 218 858 361Q858 438 820.0 498.0Q782 558 706 591Q634 622 563.5 646.5Q493 671 425 704Q335 747 280.0 827.5Q225 908 225 1009Q225 1105 267.5 1186.0Q310 1267 380 1326Q448 1383 544.5 1417.0Q641 1451 736 1451Q825 1451 904.5 1430.0Q984 1409 1064 1351L1119 1419H1199L1098 948H1017Q1014 1025 1001.5 1107.0Q989 1189 959 1243Q926 1302 867.0 1335.5Q808 1369 710 1369Q592 1369 512.0 1287.5Q432 1206 432 1094Q432 1020 461.5 968.5Q491 917 553 885Q619 851 691.5 826.5Q764 802 821 775Q936 721 1000.5 645.0Q1065 569 1065 459Q1065 353 1019.0 261.0Q973 169 896 107Q815 41 714.5 6.0Q614 -29 493 -29Z" fill="white"/></g></svg>]===],
['T'] = [===[<svg width="10" height="10" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><g transform="translate(2.2073 8.5) scale(0.003524 -0.003524)"><path d="M1455 1419 1366 1034H1297Q1296 1069 1287.5 1123.0Q1279 1177 1263 1220Q1246 1266 1218.5 1299.0Q1191 1332 1153 1338Q1123 1342 1076.5 1344.0Q1030 1346 990 1346H927L663 201Q661 193 660.0 183.5Q659 174 659 165Q659 141 668.0 125.5Q677 110 702 98Q722 90 774.5 78.5Q827 67 860 66L844 0H174L190 66Q220 68 277.0 74.0Q334 80 360 89Q400 104 420.0 130.0Q440 156 448 192L714 1346H661Q631 1346 586.0 1344.5Q541 1343 494 1338Q461 1334 417.0 1298.5Q373 1263 329 1215Q287 1168 253.0 1119.5Q219 1071 200 1034H130L219 1419Z" fill="white"/></g></svg>]===]
}
local aetheryx_status_glyphs = { }
for ch, svg in pairs(aetheryx_status_sources) do
local ok, texture = pcall(renderer.load_svg, svg, 10, 10)
if ok and texture ~= nil then aetheryx_status_glyphs[ch] = texture end
end

local function draw_aetheryx_status(text_value, center_x, y, alpha, primary, secondary)
text_value = tostring(text_value or '')
local advance, space_advance = 5.2, 3.2
local total = 0
for i = 1, #text_value do
total = total + (text_value:sub(i, i) == ' ' and space_advance or advance)
end
local cursor = center_x - total * 0.5
local count = math.max(#text_value, 1)
local wave_time = (globals.realtime() % 1.3) / 1.3
for i = 1, #text_value do
local ch = text_value:sub(i, i)
if ch == ' ' then
cursor = cursor + space_advance
else
local texture = aetheryx_status_glyphs[ch]
if texture ~= nil then
local phase = (((i / count) * 0.5) - wave_time) % 1
local mix = math.max(0, math.sin(phase * math.pi))
local r = primary[1] + (secondary[1] - primary[1]) * mix
local g = primary[2] + (secondary[2] - primary[2]) * mix
local b = primary[3] + (secondary[3] - primary[3]) * mix
local a = (primary[4] + (secondary[4] - primary[4]) * mix) * alpha
renderer.texture(texture, math.floor(cursor - 2.4), y, 10, 10, r, g, b, a)
end
cursor = cursor + advance
end
end
end

local function render_evalate_star(x, y, alpha, core)
local ar, ag, ab, aa = visual.center_indicator_color_1:get()
local sr, sg, sb, sa = visual.center_indicator_color_2:get()
ar, ag, ab, aa = ar or 184, ag or 178, ab or 225, aa or 255
sr, sg, sb, sa = sr or 255, sg or 255, sb or 255, sa or 255
local accent_a = math.floor(aa * alpha)
local text_a = math.floor(sa * alpha)
local svg_wordmark = rawget(_G, '__aetheryx_svg_wordmark')
local brand_w = svg_wordmark ~= nil and tonumber(svg_wordmark.width) or 48
local brand_h = 14

-- Use the exact per-letter SVG renderer from the Aetheryx Watermark. It is the
-- Evalate-derived renderer, not renderer.text, so both wordmarks match.
if svg_wordmark ~= nil and type(svg_wordmark.draw) == 'function' then
svg_wordmark.draw(math.floor(x - brand_w * 0.5), y - 6, alpha)
else
renderer.text(x, y + 2, 255, 255, 255, text_a, 'bc', 0, 'aetheryx')
end

local desync = math.min(1, math.abs(tonumber(localplayer.body_yaw) or 0) / 58)
local half_bar = math.floor(18 * desync + 0.5)
if half_bar > 0 then
renderer.gradient(x - half_bar, y + brand_h, half_bar, 1, ar, ag, ab, 0, ar, ag, ab, accent_a, true)
renderer.gradient(x, y + brand_h, half_bar, 1, ar, ag, ab, accent_a, ar, ag, ab, 0, true)
end

local row_y = y + brand_h + 2
local primary = {ar, ag, ab, aa}
local secondary = {sr, sg, sb, sa}
if indicator_state.dt > 0.02 then
draw_aetheryx_status('DT', x - 4, row_y - 1, alpha * indicator_state.dt, primary, secondary)
local me = entity.get_local_player()
local tickbase = me ~= nil and entity.get_prop(me, 'm_nTickBase') or nil
local ready = tickbase ~= nil and globals.tickcount() > tickbase
local charge = ready and 1 or 0.18
renderer.circle_outline(x + 4, row_y + 3, ar, ag, ab, accent_a, 3, -180, charge, 1)
row_y = row_y + 9
end
if indicator_state.hs > 0.02 then
local os_alpha = reference.is_double_tap_active() and 0.4 or 1
draw_aetheryx_status('OS', x, row_y - 1, alpha * indicator_state.hs * os_alpha, primary, secondary)
row_y = row_y + 9
end
if indicator_state.damage > 0.02 then
draw_aetheryx_status('DMG', x, row_y - 1, alpha * indicator_state.damage, primary, secondary)
row_y = row_y + 9
end
if core.safe or core.baim or core.fs then
local labels = { }
if core.safe then labels[#labels + 1] = 'SP' end
if core.baim then labels[#labels + 1] = 'BA' end
if core.fs then labels[#labels + 1] = 'FS' end
draw_aetheryx_status(table.concat(labels, '  '), x, row_y - 1, alpha, primary, secondary)
end
end
local renewed_state = {
last_name = nil,
mix = 0,
}
local function renewed_color_byte(value)
value = math.floor((tonumber(value) or 0) + 0.5)
return math.max(0, math.min(255, value))
end
local function renewed_mix_color(a, b, t)
t = clamp(tonumber(t) or 0, 0, 1)
return {
renewed_color_byte(a[1] + (b[1] - a[1]) * t),
renewed_color_byte(a[2] + (b[2] - a[2]) * t),
renewed_color_byte(a[3] + (b[3] - a[3]) * t),
renewed_color_byte(a[4] + (b[4] - a[4]) * t),
}
end
local function renewed_hex(c, alpha_mul)
local a = renewed_color_byte((c[4] or 255) * (alpha_mul or 1))
return string.format('%02X%02X%02X%02X', renewed_color_byte(c[1]), renewed_color_byte(c[2]), renewed_color_byte(c[3]), a)
end
local function renewed_animated_text(text_value, first, second, alpha_mul)
text_value = tostring(text_value or '')
if text_value == '' then return '' end
local out = { }
local now = tonumber(globals.realtime()) or 0
local length = math.max(#text_value - 1, 1)
for i = 1, #text_value do
local phase = (i - 1) / length
local wave = (math.sin(now * 2.4 + phase * math.pi * 2) + 1) * 0.5
local col = renewed_mix_color(first, second, wave)
out[#out + 1] = '\a' .. renewed_hex(col, alpha_mul)
out[#out + 1] = text_value:sub(i, i)
end
return table.concat(out)
end
local renewed_state_names = {
['STAND'] = 'STANDING',
['MOVE'] = 'MOVING',
['SLOW WALK'] = 'SLOW WALK',
['CROUCH'] = 'CROUCHING',
['CROUCH MOVE'] = 'CROUCHING',
['AIR'] = 'AIR',
['AIR CROUCH'] = 'AIR+',
['FREESTAND'] = 'FREESTAND',
['MANUAL'] = 'MANUAL',
['LEGIT'] = 'LEGIT',
}
local function render_renewed(x, y, alpha, core)
local c1r, c1g, c1b, c1a = visual.center_indicator_color_1:get()
local c2r, c2g, c2b, c2a = visual.center_indicator_color_2:get()
local primary = {c1r or 255, c1g or 25, c1b or 45, c1a or 255}
local secondary = {c2r or 255, c2g or 255, c2b or 255, c2a or 255}

local state_text = renewed_state_names[core.state] or tostring(core.state or 'STANDING'):upper()
if renewed_state.last_name ~= state_text then
renewed_state.last_name = state_text
renewed_state.mix = 1
end
renewed_state.mix = approach(renewed_state.mix, 0, 7)

local global_alpha = clamp(alpha, 0, 1)
local scope = clamp(indicator_state.scoped or 0, 0, 1)
local pos_y = y

local brand = 'aetheryx'
local brand_w, brand_h = renderer.measure_text('b', brand)
brand_w, brand_h = brand_w or 0, math.max(brand_h or 8, 8)
local brand_scope = brand_w * scope * 0.5 + scope * 3
local brand_text = renewed_animated_text(brand, secondary, primary, global_alpha)
renderer.text(
math.floor(x + brand_scope - brand_w * 0.5 + 0.5),
math.floor(pos_y - brand_h * 0.5 + 0.5),
255, 255, 255, math.floor(255 * global_alpha),
'b', 0, brand_text
)
pos_y = pos_y + brand_h - 1

local state_mix = renewed_state.mix
local state_col = renewed_mix_color(primary, secondary, state_mix)
local state_w, state_h = renderer.measure_text('-', state_text)
state_w, state_h = state_w or 0, math.max(state_h or 8, 8)
local state_scope = state_w * scope * 0.5 + scope * 3
renderer.text(
math.floor(x + state_scope - state_w * 0.5 - 1 + 0.5),
math.floor(pos_y - state_h * 0.5 + 0.5),
state_col[1], state_col[2], state_col[3],
math.floor(state_col[4] * global_alpha),
'-', 0, state_text
)
pos_y = pos_y + state_h

local function draw_row(text_value, row_alpha, color_value, addition)
row_alpha = clamp(row_alpha or 0, 0, 1)
if row_alpha <= 0.01 then return end
local rw, rh = renderer.measure_text('-', text_value)
rw, rh = rw or 0, math.max(rh or 8, 8)
local row_scope = rw * scope * 0.5 + scope * 3
local col = color_value or primary
local draw_alpha = global_alpha * row_alpha
local px = x + row_scope - rw * 0.5 - 1
renderer.text(
math.floor(px + 0.5), math.floor(pos_y - rh * 0.5 + 0.5),
col[1], col[2], col[3], math.floor((col[4] or 255) * draw_alpha),
'-', 0, text_value
)
if addition ~= nil then addition(px, pos_y, rw, draw_alpha, row_scope) end
pos_y = pos_y + rh * row_alpha
end

local damage_value = reference.is_override_minimum_damage() and reference.get_override_damage() or reference.get_minimum_damage()
draw_row('DMG ' .. tostring(damage_value), indicator_state.damage, primary)

local dt_col = primary
if core.dt and not core.charged then
    dt_col = renewed_mix_color({255, 55, 55, primary[4]}, primary, 0.18)
end
draw_row('DT', indicator_state.dt, dt_col, function(px, py, rw, draw_alpha, row_scope)
    local charge = core.charged and 1 or 0
    local cx = math.floor(x + row_scope + rw * 0.5 + 5 + 0.5)
    local cy = math.floor(py + 1 + 0.5)
    renderer.circle_outline(cx, cy, primary[1], primary[2], primary[3], math.floor(primary[4] * draw_alpha), 3, 180, math.max(0.05, charge), 1)
end)

draw_row('FREESTAND', indicator_state.fs, primary)
draw_row('OSAA', indicator_state.hs, primary)
local edge_active = safe_get(reference.antiaim.angles.edge_yaw, false) == true
indicator_state.edge = approach(indicator_state.edge or 0, edge_active and 1 or 0, 18)
draw_row('EDGE', indicator_state.edge, primary)
draw_row('BAIM', indicator_state.baim, primary)
draw_row('SP', indicator_state.safe, primary)
local def_ticks_num = core.def_ticks or 0
local def_label = def_ticks_num > 0 and ('DEF ' .. tostring(def_ticks_num) .. 'T') or 'DEF'
draw_row(def_label, indicator_state.def, primary)
draw_row('LC', indicator_state.lc, primary)
end
local function menu_signature_color_byte(value)
value = math.floor((tonumber(value) or 0) + 0.5)
return math.max(0, math.min(255, value))
end
local function menu_signature_gradient()
local color=visual_colors.get('Menu',0)
return string.format(
'\a%02X%02X%02X%02X(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧ aetheryx',
menu_signature_color_byte(color.r),
menu_signature_color_byte(color.g),
menu_signature_color_byte(color.b),
menu_signature_color_byte(color.a)
)
end
local signature_menu_was_open = false
local function update_menu_signatures()
local menu_open = ui.is_menu_open()
if not menu_open then
signature_menu_was_open = false
return
end
if signature_menu_was_open then return end
signature_menu_was_open = true
local text = menu_signature_gradient()
if menu_elements.other ~= nil
and menu_elements.other.selector ~= nil
and menu_elements.other.selector.brand ~= nil then
menu_elements.other.selector.brand:set(text)
end
if menu_elements.antiaim ~= nil
and menu_elements.antiaim.selector ~= nil
and menu_elements.antiaim.selector.brand ~= nil then
menu_elements.antiaim.selector.brand:set(text)
end
end
local center_scoped_factor = 0
local function render_center_indicators()
if not visual.center_indicators:get() then
indicator_state.alive = approach(indicator_state.alive, 0, 14)
center_scoped_factor = 0
return
end
local me = entity.get_local_player()
if me == nil or me == 0 or not entity.is_alive(me) then
indicator_state.alive = 0
indicator_state.scoped = 0
center_scoped_factor = 0
return
end
local preview = false
local core = indicator_core_state(me, preview)
local alpha = indicator_state.alive
if alpha <= 0.01 then return end

local screen_w, screen_h = client.screen_size()
local style = visual.center_indicator_style:get()
local base_x = math.floor(screen_w * 0.5)
local rail_min_y = math.floor(screen_h * 0.5)
local rail_max_y = math.floor(screen_h * 0.5 + 100)
local default_y = math.floor(screen_h * 0.5 + 20)
local box_x = base_x - 28

-- Evalate drag rail: a fixed X coordinate and a 100px vertical range.
if ui.is_menu_open() then
renderer.line(base_x, rail_min_y, base_x, rail_max_y, 255, 255, 255, 75)
renderer.rectangle(base_x - 1, rail_min_y - 1, 3, 3, 255, 255, 255, 120)
renderer.rectangle(base_x - 1, rail_max_y - 1, 3, 3, 255, 255, 255, 120)
end
local _, drag_y = drag_system.update(
'center_indicators_evalate_vertical_v1',
box_x, default_y, 55, 18,
{
min_x = box_x, max_x = box_x,
min_y = rail_min_y, max_y = rail_max_y,
default_x = box_x, default_y = default_y,
hover_distance = 12
}
)

local is_scoped = entity.get_prop(me, 'm_bIsScoped') == 1
local target_scope = is_scoped and 1.0 or 0.0
center_scoped_factor = center_scoped_factor + (target_scope - center_scoped_factor) * (globals.frametime() * 14)
center_scoped_factor = math.max(0, math.min(1, center_scoped_factor))
local scope_offset_x = math.floor(center_scoped_factor * 30)
local scope_alpha_mod = 1.0 - (center_scoped_factor * 0.45)
local final_alpha = alpha * scope_alpha_mod
local scoped_x = base_x + scope_offset_x

if style == 'Stars' then
render_stars(base_x, drag_y, alpha, core)
elseif style == 'Original' then
render_original(base_x, drag_y, alpha, core)
elseif style == 'Renewed' then
render_renewed(scoped_x, drag_y, final_alpha, core)
elseif style == 'Aetheryx' then
render_evalate_star(scoped_x, drag_y, final_alpha, core)
else
render_japanese(scoped_x + 22, drag_y, final_alpha, core)
end
end

__aetheryx_runtime.set('paint', render_center_indicators)
__aetheryx_runtime.set('paint_ui', update_menu_signatures)
end

-- Remove first-person sleeve materials. Material flags are restored exactly
-- to their previous value when the option is disabled or the Lua unloads.
local aetheryx_remove_sleeves do
local ref = menu_elements.other.miscellaneous.remove_sleeves
local MATERIAL_VAR_NO_DRAW = 2
local dirty = { }
local dirty_names = { }
local last_scan = -10
local was_enabled = false
local function material_name(material)
local ok, name = pcall(material.get_name, material)
if ok and type(name) == 'string' then return name end
return tostring(material)
end
local function restore()
for i = 1, #dirty do
local item = dirty[i]
if item.material ~= nil then
pcall(item.material.set_material_var_flag, item.material, MATERIAL_VAR_NO_DRAW, item.original)
end
end
dirty = { }
dirty_names = { }
was_enabled = false
end
local function apply_material(material)
if material == nil then return end
local name = material_name(material)
local lname = string.lower(name or '')
if not lname:find('sleeve', 1, true) then return end
if not (lname:find('models/weapons', 1, true) or lname:find('arms', 1, true)) then return end
if dirty_names[name] then return end
local ok, old = pcall(material.get_material_var_flag, material, MATERIAL_VAR_NO_DRAW)
if not ok then return end
dirty_names[name] = true
dirty[#dirty + 1] = { material = material, original = old == true }
pcall(material.set_material_var_flag, material, MATERIAL_VAR_NO_DRAW, true)
end
local function scan()
if type(materialsystem) ~= 'table' or type(materialsystem.find_materials) ~= 'function' then return end
local ok, materials = pcall(materialsystem.find_materials, 'models/weapons/v_models', false)
if not ok or type(materials) ~= 'table' then return end
for i = 1, #materials do apply_material(materials[i]) end
end
local function update()
local enabled = ref ~= nil and ref.checkbox ~= nil and ref.checkbox:get() == true
if not enabled then
if was_enabled or #dirty > 0 then restore() end
return
end
was_enabled = true
local now = globals.realtime()
if now - last_scan >= 1.0 then
last_scan = now
scan()
end
end
__aetheryx_runtime.set('paint_ui', update)
__aetheryx_runtime.set('level_init', function() restore(); last_scan = -10 end)
__aetheryx_runtime.set('shutdown', restore)
end

local manual_arrows_hud = { } do
local ref = menu_elements.antiaim.features.manual_yaw
local offset = 40
local scope_anim = 0
local left_alpha = 0
local right_alpha = 0

local function clamp(value, minimum, maximum)
return math.max(minimum, math.min(maximum, value))
end

local function approach(current, target, speed)
local dt = clamp(tonumber(globals.frametime()) or 0, 0, 0.05)
return current + (target - current) * math.min(1, dt * speed)
end

local stable_desync_side = 0
local pending_desync_side = 0
local pending_desync_since = 0

local function desync_side()
local value = tonumber(aa_runtime_state.desync_offset)
if value == nil or math.abs(value) < 0.5 then
value = tonumber(localplayer.body_yaw) or 0
end
local candidate = 0
if value < -0.5 then candidate = -1
elseif value > 0.5 then candidate = 1 end
local now = globals.realtime()
if stable_desync_side == 0 and candidate ~= 0 then
stable_desync_side = candidate
pending_desync_side = candidate
pending_desync_since = now
return stable_desync_side
end
if candidate ~= pending_desync_side then
pending_desync_side = candidate
pending_desync_since = now
elseif candidate ~= 0 and candidate ~= stable_desync_side
and now - pending_desync_since >= 0.18 then
stable_desync_side = candidate
end
return stable_desync_side
end

local function color(active, accent, secondary, alpha)
local source = active and accent or secondary
return source[1], source[2], source[3], math.floor((source[4] or 255) * alpha + 0.5)
end

local function draw_invictus(cx, cy, manual, side, accent, secondary, alpha)
local dynamic = ref.arrows_dynamic:get()
local left_text = dynamic and side < 0 and '<<' or '<'
local right_text = dynamic and side > 0 and '>>' or '>'
local lr,lg,lb,la = color(manual == 'left', accent, secondary, alpha)
local rr,rg,rb,ra = color(manual == 'right', accent, secondary, alpha)
local _, left_h = renderer.measure_text('+', left_text)
local _, right_h = renderer.measure_text('+', right_text)
local left_y = math.floor(cy - 1 - (left_h or 10) * 0.5 + 0.5)
local right_y = math.floor(cy - 1 - (right_h or 10) * 0.5 + 0.5)
renderer.text(cx - offset, left_y, lr,lg,lb,la, 'cr+', 0, left_text)
renderer.text(cx + offset, right_y, rr,rg,rb,ra, 'c+', 0, right_text)
end

local function draw_modern(cx, cy, manual, accent, secondary, alpha)
local lr,lg,lb,la = color(manual == 'left', accent, secondary, alpha)
local rr,rg,rb,ra = color(manual == 'right', accent, secondary, alpha)
renderer.text(cx - offset, cy - 7, lr,lg,lb,la, 'cr+', 0, '\238\130\158')
renderer.text(cx + offset, cy - 7, rr,rg,rb,ra, 'c+', 0, '\238\130\159')
end

local function draw_ambani(cx, cy, manual, side, accent, secondary, alpha, dpi)
local dynamic = ref.arrows_dynamic:get()
local left_text = dynamic and side < 0 and '❮❮' or '❮'
local right_text = dynamic and side > 0 and '❯❯' or '❯'
local lr,lg,lb,la = color(manual == 'left', accent, secondary, alpha)
local rr,rg,rb,ra = color(manual == 'right', accent, secondary, alpha)
local y = cy - math.floor(7 * dpi) - 1
renderer.text(cx - offset, y, lr,lg,lb,la, 'cr', 0, left_text)
renderer.text(cx + offset, y, rr,rg,rb,ra, 'c', 0, right_text)
end

local function draw_teamskeet(cx, cy, manual, side, accent, secondary, alpha, dpi)
local width = math.max(2, math.floor(2 * dpi + 0.5))
local arrow = math.max(8, math.floor(13 * dpi + 0.5))
local height = math.max(6, math.floor(9 * dpi + 0.5))
local disabled = {35,35,35,150}
local lr,lg,lb,la = color(manual == 'left', accent, disabled, alpha)
local rr,rg,rb,ra = color(manual == 'right', accent, disabled, alpha)
local dlr,dlg,dlb,dla = color(side < 0, secondary, disabled, alpha)
local drr,drg,drb,dra = color(side > 0, secondary, disabled, alpha)
renderer.triangle(cx-offset-arrow*2,cy,cx-offset-arrow,cy-height,cx-offset-arrow,cy+height,lr,lg,lb,la)
renderer.triangle(cx+offset+arrow*2,cy,cx+offset+arrow,cy-height,cx+offset+arrow,cy+height,rr,rg,rb,ra)
renderer.rectangle(cx-offset-arrow+width+2,cy-height,-width,height*2,dlr,dlg,dlb,dla)
renderer.rectangle(cx+offset+arrow-width-2,cy-height,width,height*2,drr,drg,drb,dra)
end

local function get_dpi()
if reference ~= nil and type(reference.get_dpi) == 'function' then
local ok, value = pcall(reference.get_dpi)
if ok and tonumber(value) ~= nil then return tonumber(value) end
end
return 1
end

local function on_paint()
if not ref.checkbox:get() or not ref.arrows:get() then return end
local me = entity.get_local_player()
if me == nil or not entity.is_alive(me) then return end
local manual = aa_runtime_state.manual_direction
local side = desync_side()
if manual == nil and side == 0 then return end
local style = ref.arrows_style:get()
offset = ref.arrows_offset:get()
local scoped = entity.get_prop(me, 'm_bIsScoped') == 1
scope_anim = approach(scope_anim, ref.arrows_animate_scope:get() and scoped and 1 or 0, 12)
local scope_shift = math.floor(20 * scope_anim + 0.5)
local sw, sh = client.screen_size()
local cx, cy = math.floor(sw * 0.5), math.floor(sh * 0.5)
local ar,ag,ab,aa = ref.arrows_color:get()
local sr,sg,sb,sa = ref.arrows_secondary:get()
local accent = {ar,ag,ab,aa}
local secondary = {sr,sg,sb,sa}
left_alpha = approach(left_alpha, manual == 'left' and 1 or 0.62, 12)
right_alpha = approach(right_alpha, manual == 'right' and 1 or 0.62, 12)
local alpha = math.max(left_alpha, right_alpha)
local original = offset
offset = original + scope_shift
if style == 'Invictus' then draw_invictus(cx,cy,manual,side,accent,secondary,alpha)
elseif style == 'Modern' then draw_modern(cx,cy,manual,accent,secondary,alpha)
elseif style == 'Ambani' then draw_ambani(cx,cy,manual,side,accent,secondary,alpha,get_dpi())
else draw_teamskeet(cx,cy,manual,side,accent,secondary,alpha,get_dpi()) end
offset = original
end

__aetheryx_runtime.set('paint', on_paint)
end
local hitrate_indicator do
local ref = menu_elements.other.miscellaneous.hitrate
local key = 'aetheryx_hitrate_stats_v1'
local stored = database.read(key)
local stats = type(stored) == 'table' and stored or {total_shots = 0, hits = 0}
stats.total_shots = math.max(0, tonumber(stats.total_shots) or 0)
stats.hits = math.max(0, math.min(tonumber(stats.hits) or 0, stats.total_shots))
local function save() database.write(key, stats) end
local function reset()
stats = {total_shots = 0, hits = 0}
save()
end
local function on_paint()
if not ref.checkbox:get() then return end
local me = entity.get_local_player()
if me == nil or not entity.is_alive(me) then return end
local ratio = stats.total_shots > 0 and stats.hits / stats.total_shots * 100 or 0
renderer.indicator(200, 200, 200, 255,
string.format('%d/%d (%.1f%%)', stats.hits, stats.total_shots, ratio))
end
local function on_hit()
stats.total_shots = stats.total_shots + 1
stats.hits = stats.hits + 1
save()
end
local function on_miss(e)
local reason = tostring(e.reason or '')
if reason == 'death' or reason == 'unregistered shot' then return end
stats.total_shots = stats.total_shots + 1
save()
end
ref.reset:set_callback(reset)
__aetheryx_runtime.set('paint', on_paint)
__aetheryx_runtime.set('aim_hit', on_hit)
__aetheryx_runtime.set('aim_miss', on_miss)
end
local min_damage_indicator do
local ref = menu_elements.other.visual
local value = reference.get_minimum_damage()
local function current_damage()
local damage = reference.is_override_minimum_damage()
and reference.get_override_damage()
or reference.get_minimum_damage()
return math.max(0, tonumber(damage) or 0)
end
local function outline(x, y, width, height, r, g, b, a)
renderer.rectangle(x, y, width, 1, r, g, b, a)
renderer.rectangle(x, y + height - 1, width, 1, r, g, b, a)
renderer.rectangle(x, y, 1, height, r, g, b, a)
renderer.rectangle(x + width - 1, y, 1, height, r, g, b, a)
end
local function min_damage_color()
local ok,r,g,b,a=pcall(ref.min_damage_color.get,ref.min_damage_color)
if not ok or type(r)~='number' then return 255,255,255,255 end
return r,g,b,type(a)=='number' and a or 255
end
local function on_paint()
if ref.min_damage_indicator == nil or not ref.min_damage_indicator:get() then return end
local me = entity.get_local_player()
local preview = ui.is_menu_open()
local alive = me ~= nil and entity.is_alive(me)
if not alive and not preview then return end
local damage = preview and (alive and current_damage() or 50) or current_damage()
local factor = math.min(math.max(globals.frametime(), 0) * 12, 1)
value = value + (damage - value) * factor
local screen_w, screen_h = client.screen_size()
local center_x, center_y = math.floor(screen_w * 0.5), math.floor(screen_h * 0.5)
if preview then
outline(center_x - 82, center_y - 82, 164, 164, 255, 255, 255, 65)
end
local x, y = drag_system.update('min_damage_indicator', center_x + 10, center_y - 18, 24, 18)
local r,g,b,a=min_damage_color()
renderer.text(x + 12, y + 4, r, g, b, a, 'c', 0, tostring(math.floor(value + 0.5)))
end
__aetheryx_runtime.set('paint', on_paint)
end
local event_logs = { } do
local ref = menu_elements.other.visual
local entries, shots = { }, { }
local last_shot = nil
local fade_time = 0.45
local hitgroups = {[0]='generic',[1]='head',[2]='chest',[3]='stomach',[4]='left arm',[5]='right arm',[6]='left leg',[7]='right leg',[8]='neck',[9]='generic',[10]='gear'}
local weapon_actions = {inferno='Burned',knife='Knifed',hegrenade='Naded'}
local weapon_names = {ak47='AK-47',awp='AWP',ssg08='SSG-08',scar20='SCAR-20',g3sg1='G3SG1',deagle='Desert Eagle',revolver='R8 Revolver',elite='Dual Berettas',hegrenade='HE Grenade',smokegrenade='Smoke Grenade',flashbang='Flashbang',molotov='Molotov',incgrenade='Incendiary Grenade',defuser='Defuse Kit',vesthelm='Kevlar + Helmet',vest='Kevlar'}
local function pretty_weapon(name)
name=tostring(name or 'unknown'):gsub('^weapon_',''):gsub('^item_','')
return weapon_names[name] or name:gsub('_',' ')
end
local function get_log_prefix()
return 'aetheryx'
end
local function round_signed(value)
value=tonumber(value) or 0
return value>=0 and math.floor(value+0.5) or math.ceil(value-0.5)
end
local function tick_to_ms(ticks)
return round_signed((tonumber(ticks) or 0)*globals.tickinterval()*1000)
end
local function damage_delta(predicted,actual)
predicted=tonumber(predicted) or 0
actual=tonumber(actual) or 0
local delta=actual-predicted
return delta>=0 and ('+'..tostring(math.floor(delta+0.5))) or tostring(math.ceil(delta-0.5))
end

-- Combo v1: reason-aware, temporary per-enemy helper overrides.
local aetheryx_aimbot_helper_runtime = { } do
local ref = menu_elements.other.aimbot_helper
local ping_refs = { ui.reference('Misc','Miscellaneous','Ping spike') }
local ping_value = ping_refs[3]
local player_data, saved, damage_cache = {}, {}, {}
local last_weapon=nil
local function restore_plist(ent,key)
    local s=saved[ent] and saved[ent][key]
    if not s then return end
    local ok,current=pcall(plist.get,ent,key)
    if ok and current==s.last then pcall(plist.set,ent,key,s.original) end
    saved[ent][key]=nil
end
local function set_plist(ent,key,value)
    if value==nil then restore_plist(ent,key);return end
    saved[ent]=saved[ent] or {}
    if not saved[ent][key] then saved[ent][key]={original=plist.get(ent,key)} end
    if plist.get(ent,key)~=value then plist.set(ent,key,value) end
    saved[ent][key].last=value
end
local function restore_all()
    for ent,t in pairs(saved) do for key in pairs(t) do restore_plist(ent,key) end end
    saved={}
    if ping_value then override.unset(ping_value) end
end
local function clear()
    restore_all();player_data={};damage_cache={};last_weapon=nil
end
local function get_weapon_type(weapon)
    local info=csgo_weapons(weapon)
    if not info then return nil end
    local t,idx=info.type,info.idx
    if t=='sniperrifle' then return idx==40 and 'Scout' or idx==9 and 'AWP' or 'Auto Snipers' end
    if t=='pistol' then return idx==1 and 'Desert Eagle' or idx==64 and 'R8 Revolver' or 'Pistols' end
    return ({rifle='Rifle',shotgun='Shotgun',smg='SMG',machinegun='Machine gun'})[t]
end
local function wants_lethal(items)
    for _,key in ipairs({'force_safe_point','prefer_body_aim','force_body_aim'}) do
        local option=({force_safe_point='Force safe point',prefer_body_aim='Prefer body aim',force_body_aim='Force body aim'})[key]
        if items.options:get(option) and items[key].triggers:get('Lethal') then return true end
    end
    return false
end
local function estimated_body_damage(me,enemy,weapon)
    local ox,oy,oz=client.eye_position()
    local tx,ty,tz=entity.get_origin(enemy)
    if not ox or not tx then return nil end
    local now=globals.realtime()
    local cached=damage_cache[enemy]
    if cached and cached.weapon==weapon and now-cached.time<0.12
        and (ox-cached.ox)^2+(oy-cached.oy)^2+(oz-cached.oz)^2<64
        and (tx-cached.tx)^2+(ty-cached.ty)^2+(tz-cached.tz)^2<64 then
        return cached.damage
    end
    local best=nil
    for _,box in ipairs({2,3,4}) do
        local x,y,z=entity.hitbox_position(enemy,box)
        if x then
            local ok,hit,damage=pcall(client.trace_bullet,me,ox,oy,oz,x,y,z)
            if ok and hit==enemy and type(damage)=='number' and damage>0 then
                best=math.max(best or 0,damage)
            end
        end
    end
    damage_cache[enemy]={weapon=weapon,time=now,damage=best,
        ox=ox,oy=oy,oz=oz,tx=tx,ty=ty,tz=tz}
    return best
end
local function triggered(g,ctx)
    if not g then return false end
    if g.triggers:get('Enemy HP < X') and ctx.health<g.hp:get() then return true end
    if g.triggers:get('X missed shots') and ctx.misses>=g.missed_shots:get() then return true end
    if g.triggers:get('Lethal') and aetheryx_combo_core.lethal(ctx.health,ctx.damage,ref.lethal_margin:get()) then return true end
    if g.triggers:get('Height advantage') and ctx.height>70 then return true end
    if g.triggers:get('Enemy higher than you') and ctx.height< -70 then return true end
    return false
end
local function update()
    if not ref.checkbox:get() then clear();return end
    local me=entity.get_local_player()
    if not me or not entity.is_alive(me) then clear();return end
    local weapon=entity.get_player_weapon(me)
    if weapon~=last_weapon then restore_all();damage_cache={};last_weapon=weapon end
    local wt=weapon and get_weapon_type(weapon)
    local items=wt and ref[wt]
    if not items then restore_all();return end
    local enemies=entity.get_players(true) or {}
    local seen={}
    local _,_,mz=entity.get_origin(me)
    local estimate=wants_lethal(items)
    local threat=client.current_threat()
    -- Trace at most four targets per command; current threat gets first budget.
    if threat then
        for i=1,#enemies do if enemies[i]==threat then enemies[1],enemies[i]=enemies[i],enemies[1];break end end
    end
    local budget=4
    for i=1,#enemies do
        local enemy=enemies[i]
        if entity.is_alive(enemy) and not entity.is_dormant(enemy) then
            seen[enemy]=true
            local _,_,ez=entity.get_origin(enemy)
            local d=player_data[enemy]
            if d and globals.realtime()-d.time>=ref.miss_decay:get() then player_data[enemy]=nil;d=nil end
            local ctx={health=entity.get_prop(enemy,'m_iHealth') or 100,
                misses=d and d.misses or 0,height=(mz or 0)-(ez or 0)}
            if estimate and budget>0 then ctx.damage=estimated_body_damage(me,enemy,weapon);budget=budget-1 end
            local safe,body=nil,nil
            if items.options:get('Force safe point') and triggered(items.force_safe_point,ctx) then safe='On' end
            if items.options:get('Force body aim') and triggered(items.force_body_aim,ctx) then body='Force'
            elseif items.options:get('Prefer body aim') and triggered(items.prefer_body_aim,ctx) then body='On' end
            set_plist(enemy,'Override safe point',safe)
            set_plist(enemy,'Override prefer body aim',body)
        end
    end
    for enemy,t in pairs(saved) do
        if not seen[enemy] then
            for key in pairs(t) do restore_plist(enemy,key) end
            saved[enemy]=nil;damage_cache[enemy]=nil
        end
    end
    if ping_value then
        if items.options:get('Ping spike') then override.set(ping_value,items.ping_spike.value:get()) else override.unset(ping_value) end
    end
end
client.set_event_callback('aim_miss',function(e)
    if not ref.checkbox:get() or not e.target then return end
    local kind=aetheryx_combo_core.reason(e.reason)
    -- Spread and prediction errors NEVER drive miss-based overrides.
    if kind=='Spread' or kind=='Prediction' or not ref.miss_reasons:get(kind) then return end
    local now=globals.realtime()
    local d=player_data[e.target]
    if not d or now-d.time>=ref.miss_decay:get() then d={misses=0,reasons={}};player_data[e.target]=d end
    d.misses=d.misses+1;d.time=now;d.reasons[kind]=(d.reasons[kind] or 0)+1
end)
client.set_event_callback('aim_hit',function(e)
    if e.target then
        player_data[e.target]=nil;damage_cache[e.target]=nil
        restore_plist(e.target,'Override safe point');restore_plist(e.target,'Override prefer body aim')
    end
end)
local function clear_player(e)
    local ent=client.userid_to_entindex(e.userid)
    if ent then
        restore_plist(ent,'Override safe point');restore_plist(ent,'Override prefer body aim')
        player_data[ent]=nil;damage_cache[ent]=nil;saved[ent]=nil
    end
end
client.set_event_callback('player_spawn',clear_player)
client.set_event_callback('player_death',clear_player)
client.set_event_callback('player_disconnect',function()clear()end)
client.set_event_callback('round_prestart',clear)
client.set_event_callback('level_init',clear)
client.set_event_callback('setup_command',update)
client.set_event_callback('shutdown',clear)
ref.checkbox:set_callback(function()if not ref.checkbox:get() then clear() end end)
end
local function safe_player_name(index)
local ok,name=pcall(entity.get_player_name,index)
if ok and type(name)=='string' and name~='' then return name end
return 'unknown'
end

local function safe_player_health(index)
local ok,health=pcall(entity.get_prop,index,'m_iHealth')
if not ok then return 0 end
return math.max(tonumber(health) or 0,0)
end

local function control_color(item,fr,fg,fb,fa)
if item==nil then return fr,fg,fb,fa end
local ok,r,g,b,a=pcall(item.get,item)
if not ok or type(r)~='number' then return fr,fg,fb,fa end
return r,g,b,type(a)=='number' and a or fa
end
local function strip_log_markup(text)
return tostring(text or '')
:gsub('/[vr]', '')
:gsub('\a%x%x%x%x%x%x%x%x', '')
end

-- aimbot_logging_3.lua port -------------------------------------------------
-- The console classifier below intentionally keeps the original logger's
-- shot bookkeeping, net-channel diagnostics, safety state and output strings.
-- Screen cards are kept separate so the console output stays 1:1.
local reference_logger = { }
do
local aim_data = { }
local bullet_impacts = { }
local prefer_safe_point = ui.reference('RAGE', 'Aimbot', 'Prefer safe point')
local force_safe_point = ui.reference('RAGE', 'Aimbot', 'Force safe point')

local function num_format(b)
local c=b%10
if c==1 and b~=11 then return b..'st'
elseif c==2 and b~=12 then return b..'nd'
elseif c==3 and b~=13 then return b..'rd'
else return b..'th' end
end

local ref_hitgroup_names = { 'generic', 'head', 'chest', 'stomach', 'left arm', 'right arm', 'left leg', 'right leg', 'neck', '?', 'gear' }
local ref_weapon_to_verb = { knife = 'Knifed', hegrenade = 'Naded', inferno = 'Burned' }

local net_channel = { }
do
local class_ptr = ffi.typeof('void***')
local engine_client = ffi.cast(class_ptr, client.create_interface('engine.dll', 'VEngineClient014'))
local get_channel = ffi.cast('void*(__thiscall*)(void*)', engine_client[0][78])
local netc_bool = ffi.typeof('bool(__thiscall*)(void*)')
local netc_bool2 = ffi.typeof('bool(__thiscall*)(void*, int, int)')
local netc_float = ffi.typeof('float(__thiscall*)(void*, int)')
local netc_int = ffi.typeof('int(__thiscall*)(void*, int)')

function net_channel:update()
local raw = get_channel(engine_client)
if raw == nil then return end
local ncu_info = ffi.cast(class_ptr, raw)
if ncu_info == nil then return end
local seqNr_out = ffi.cast(netc_int, ncu_info[0][17])(ncu_info, 1)
self.seqNr_out = seqNr_out
self.is_loopback = ffi.cast(netc_bool, ncu_info[0][6])(ncu_info)
self.is_timing_out = ffi.cast(netc_bool, ncu_info[0][7])(ncu_info)
self.latency = {
crn = function(flow) return ffi.cast(netc_float, ncu_info[0][9])(ncu_info, flow) end,
average = function(flow) return ffi.cast(netc_float, ncu_info[0][10])(ncu_info, flow) end
}
self.loss = ffi.cast(netc_float, ncu_info[0][11])(ncu_info, 1)
self.choke = ffi.cast(netc_float, ncu_info[0][12])(ncu_info, 1)
self.got_bytes = ffi.cast(netc_float, ncu_info[0][13])(ncu_info, 1)
self.sent_bytes = ffi.cast(netc_float, ncu_info[0][13])(ncu_info, 0)
self.is_valid_packet = ffi.cast(netc_bool2, ncu_info[0][18])(ncu_info, 1, seqNr_out-1)
end

function net_channel:get()
return self.seqNr_out ~= nil and self or nil
end
end

local function generate_flags(pre_data)
return {
pre_data.self_choke > 1 and 1 or 0,
pre_data.velocity_modifier < 1.00 and 1 or 0,
pre_data.flags.boosted and 1 or 0
}
end

local function get_safety(data, target)
local has_been_boosted = data.boosted
local plist_safety = plist.get(target, 'Override safe point')
local ui_safety = { ui.get(prefer_safe_point), ui.get(force_safe_point) or plist_safety == 'On' }
if not has_been_boosted then return -1 end
if plist_safety == 'Off' or not (ui_safety[1] or ui_safety[2]) then return 0 end
return ui_safety[2] and 2 or (ui_safety[1] and 1 or 0)
end

local function get_inaccuracy_tick(pre_data, tick)
local spread_angle = -1
for _, impact in pairs(bullet_impacts) do
if impact.tick == tick then
local aim, shot = (pre_data.eye-pre_data.shot_pos):angles(), (pre_data.eye-impact.shot):angles()
spread_angle = vector(aim-shot):length2d()
break
end
end
return spread_angle
end

function reference_logger.fired(e)
if not ref.event_logs:get() then return end
local me = entity.get_local_player()
aim_data[e.id] = {
original = e,
dropped_packets = { },
handle_time = globals.realtime(),
self_choke = globals.chokedcommands(),
flags = { boosted = e.boosted },
safety = get_safety(e, e.target),
correction = plist.get(e.target, 'Correction active'),
shot_pos = vector(e.x, e.y, e.z),
eye = vector(client.eye_position()),
view = vector(client.camera_angles()),
velocity_modifier = entity.get_prop(me, 'm_flVelocityModifier'),
total_hits = entity.get_prop(me, 'm_totalHitsOnServer'),
history = globals.tickcount() - e.tick
}
end

function reference_logger.missed(e)
if not ref.event_logs:get() then return e.reason == '?' and 'unknown' or (e.reason or 'unknown') end
if aim_data[e.id] == nil then
return e.reason == '?' and 'unknown' or (e.reason or 'unknown')
end
local pre_data = aim_data[e.id]
local shot_id = num_format((e.id % 15) + 1)
local net_data = net_channel:get()
local ping, avg_ping = 0, 0
if net_data ~= nil and net_data.latency ~= nil then
ping = net_data.latency.crn(0)*1000
avg_ping = net_data.latency.average(0)*1000
end
local net_state = string.format('delay: %d:%.2f | dropped: %d', avg_ping, math.abs(avg_ping-ping), #pre_data.dropped_packets)
local cc = cvar.cl_clock_correction and cvar.cl_clock_correction:get_int() or 0
local cs = cvar.cl_clock_correction_force_server_tick and cvar.cl_clock_correction_force_server_tick:get_int() or 0
local uflags = {
math.abs(avg_ping-ping) < 1 and 0 or 1,
cc == 1 and 0 or 1,
cs == 999 and 0 or 1
}
local spread_angle = get_inaccuracy_tick(pre_data, globals.tickcount())
local me = entity.get_local_player()
local hgroup = ref_hitgroup_names[e.hitgroup + 1] or '?'
local target_name = string.lower(entity.get_player_name(e.target) or 'unknown')
local hit_chance = math.floor(pre_data.original.hit_chance + 0.5)
local pflags = generate_flags(pre_data)
local post_data = {
event_timeout = (globals.realtime() - pre_data.handle_time) >= 0.5,
damage_rejected = e.reason == '?' and pre_data.total_hits ~= entity.get_prop(me, 'm_totalHitsOnServer'),
prediction_error = e.reason == 'prediction error' or e.reason == 'unregistered shot'
}
local screen_reason = e.reason == '?' and 'unknown' or (e.reason or 'unknown')
local console_line = nil
if post_data.event_timeout then
console_line = string.format('Missed %s shot due to event timeout [%s] [%s]', shot_id, target_name, net_state)
print(console_line)
screen_reason = 'event timeout'
elseif post_data.prediction_error then
local suffix = e.reason == 'unregistered shot' and (' [' .. e.reason .. ']') or ''
console_line = string.format('Missed %s shot at %s\'s %s(%s%%) due to prediction error%s [%s] [vel_modifier: %.1f | history(Δ): %d | error: %s]', shot_id, target_name, hgroup, hit_chance, suffix, net_state, entity.get_prop(me, 'm_flVelocityModifier'), pre_data.history, table.concat(uflags))
print(console_line)
screen_reason = 'prediction error'
elseif e.reason == 'spread' then
console_line = string.format('Missed %s shot at %s\'s %s(%s%%) due to spread ( dmg: %d | safety: %d | history(Δ): %d | flags: %s )', shot_id, target_name, hgroup, hit_chance, spread_angle, pre_data.original.damage, pre_data.safety, pre_data.history, table.concat(pflags))
print(console_line)
screen_reason = 'spread'
elseif e.reason == '?' then
local reason = post_data.damage_rejected and 'damage rejection' or string.format('unknown [angle: ?° | ?°]')
console_line = string.format('Missed %s shot at %s\'s %s(%s%%) due to %s ( dmg: %d | safety: %d | history(Δ): %d | flags: %s )', shot_id, target_name, hgroup, hit_chance, reason, pre_data.original.damage, pre_data.safety, pre_data.history, table.concat(pflags))
print(console_line)
screen_reason = post_data.damage_rejected and 'damage rejection' or 'unknown'
elseif e.reason == 'death' then
console_line = string.format('Missed %s shot at %s\'s %s(%s%%) due to death [dropped: %d | flags: %s | error: %s]', shot_id, target_name, hgroup, hit_chance, #pre_data.dropped_packets, table.concat(pflags), table.concat(uflags))
print(console_line)
screen_reason = 'death'
end
aim_data[e.id] = nil
return screen_reason, console_line
end

function reference_logger.hit(e)
if not ref.event_logs:get() then return end
if aim_data[e.id] == nil then return end
local pre_data = aim_data[e.id]
local shot_id = num_format((e.id % 15) + 1)
local hgroup = ref_hitgroup_names[e.hitgroup + 1] or '?'
local aimed_hgroup = ref_hitgroup_names[pre_data.original.hitgroup + 1] or '?'
local target_name = string.lower(entity.get_player_name(e.target) or 'unknown')
local hit_chance = math.floor(pre_data.original.hit_chance + 0.5)
local pflags = generate_flags(pre_data)
local function verification()
local text = ''
local hg_diff = hgroup ~= aimed_hgroup
local dmg_diff = e.damage ~= pre_data.original.damage
if hg_diff or dmg_diff then
text = string.format(' | mismatch: [ %s ]', (function()
local addr = ''
if dmg_diff then addr = 'dmg: ' .. pre_data.original.damage .. (hg_diff and ' | ' or '') end
if hg_diff then addr = addr .. (hg_diff and 'hitgroup: ' .. aimed_hgroup or '') end
return addr
end)())
end
return text
end
local console_line = string.format('Registered %s shot in %s\'s %s for %d damage ( hitchance: %d%% | safety: %s | history(Δ): %d | flags: %s%s )', shot_id, target_name, hgroup, e.damage, hit_chance, pre_data.safety, pre_data.history, table.concat(pflags), verification())
print(console_line)
aim_data[e.id] = nil
return console_line
end

function reference_logger.bullet_impact(e)
if not ref.event_logs:get() then return end
local tick = globals.tickcount()
local me = entity.get_local_player()
local user = client.userid_to_entindex(e.userid)
if user ~= me then return end
if #bullet_impacts > 150 then bullet_impacts = { } end
bullet_impacts[#bullet_impacts+1] = { tick=tick, eye=vector(client.eye_position()), shot=vector(e.x,e.y,e.z) }
end

function reference_logger.net_update_start()
if not ref.event_logs:get() then return end
net_channel:update()
local net_data = net_channel:get()
if net_data == nil then return end
if not net_channel.is_valid_packet then
for id in pairs(aim_data) do
table.insert(aim_data[id].dropped_packets, net_channel.seqNr_out)
end
end
end

function reference_logger.player_hurt(e)
if not ref.event_logs:get() then return end
local attacker_id = client.userid_to_entindex(e.attacker)
if attacker_id == nil or attacker_id ~= entity.get_local_player() then return end
local group = ref_hitgroup_names[e.hitgroup + 1] or '?'
if group == 'generic' and ref_weapon_to_verb[e.weapon] ~= nil then
local target_id = client.userid_to_entindex(e.userid)
local target_name = entity.get_player_name(target_id)
print(string.format('%s %s for %i damage (%i remaining)', ref_weapon_to_verb[e.weapon], string.lower(target_name), e.dmg_health, e.health))
end
end
end

function event_logs.push(text,kind,meta)
if not ref.event_logs:get() or not ref.event_log_show_screen:get() then return end
text=tostring(text or '')
local ok_sr, sr, sg, sb, sa = pcall(ref.event_log_text_color.get, ref.event_log_text_color)
if not ok_sr or type(sr) ~= 'number' then sr, sg, sb, sa = 245, 245, 245, 255 end
local color = { sr, sg, sb }
if kind == 'miss' then color = { 200, 100, 120 } end
entries[#entries+1]={
text=text,
segments=type(meta)=='table' and meta.screen_segments or nil,
modern_text=type(meta)=='table' and meta.modern_text or nil,
modern_segments=type(meta)=='table' and meta.modern_segments or nil,
subtitle=type(meta)=='table' and meta.screen_subtitle or nil,
subtitle_segments=type(meta)=='table' and meta.screen_subtitle_segments or nil,
kind=kind or 'info',
time=globals.realtime(),
alpha=0,
scale=0,
y=16,
icon_type=kind or 'info',
color=color
}
while #entries>5 do table.remove(entries,1) end
end
local function event_backtrack_ticks(e)
-- GameSense aim_fire.backtrack is already the amount of backtrack ticks.
-- e.tick is the shot tick, so globals.tickcount()-e.tick is NOT a safe
-- substitute and could produce misleading values such as -9t.
local backtrack = tonumber(e and e.backtrack) or 0
local raw_ticks = round_signed(backtrack)
-- Legacy safety/display rule requested for Aetheryx: never show deeper
-- negative extrapolation than -3 ticks. Positive backtrack is preserved.
return math.max(-3, math.min(64, raw_ticks))
end

local function on_aim_fire(e)
reference_logger.fired(e)
local bt_ticks=event_backtrack_ticks(e)
local data={
hc=math.floor((e.hit_chance or 0)+0.5),
bt=bt_ticks,
predicted_dmg=tonumber(e.damage) or 0,
predicted_hitgroup=tonumber(e.hitgroup) or 0
}
shots[e.id or 0]=data; last_shot=data
end
local function take_shot(e)
local id=e.id or 0; local data=shots[id] or last_shot
shots[id]=nil; if data==last_shot then last_shot=nil end
return data
end
local function on_aim_hit(e)
local console_line = reference_logger.hit(e)
local name=safe_player_name(e.target)
local group=hitgroups[e.hitgroup] or 'generic'
local health=safe_player_health(e.target)
local shot=take_shot(e) or {
hc=math.floor((e.hit_chance or 0)+0.5),
bt=0,
predicted_dmg=tonumber(e.damage) or 0,
predicted_hitgroup=tonumber(e.hitgroup) or 0
}
shot.event='Hits'
local damage=tonumber(e.damage) or 0
local bt=round_signed(shot.bt)
local ms=tick_to_ms(bt)
local delta=damage_delta(shot.predicted_dmg,damage)
local ar,ag,ab,aa=control_color(ref.event_log_text_color,210,140,255,255)
local msg=string.format(
"Hit %s in the %s for %d (%d health remaining)",
name,group,damage,health
)
shot.screen_segments={
{text='Hit ',color={215,215,218}},
{text=name,color={ar,ag,ab}},
{text=' in the ',color={215,215,218}},
{text=group,color={ar,ag,ab}},
{text=' for ',color={215,215,218}},
{text=tostring(damage),color={ar,ag,ab}},
{text=' (',color={215,215,218}},
{text=tostring(health),color={ar,ag,ab}},
{text=' health remaining)',color={215,215,218}}
}

shot.modern_text=string.format(
'Hit %s in the %s for %d damage (%d health remaining)',
name,group,damage,health
)
shot.modern_segments={
{text='Hit ',color={200,200,200}},
{text=name,color={ar,ag,ab}},
{text=' in the ',color={200,200,200}},
{text=group,color={ar,ag,ab}},
{text=' for ',color={200,200,200}},
{text=tostring(damage),color={ar,ag,ab}},
{text=' damage (',color={200,200,200}},
{text=tostring(health),color={ar,ag,ab}},
{text=' health remaining)',color={200,200,200}}
}

local predicted_group=hitgroups[tonumber(shot.predicted_hitgroup) or 0] or 'generic'
local predicted_damage=tonumber(shot.predicted_dmg) or damage
local mismatch_parts={}

if predicted_damage~=damage then
mismatch_parts[#mismatch_parts+1]=string.format('dmg %d→%d',predicted_damage,damage)
end
if predicted_group~=group then
mismatch_parts[#mismatch_parts+1]=string.format('%s→%s',predicted_group,group)
end

if #mismatch_parts>0 then
local aimed_group=predicted_group
shot.screen_subtitle=string.format('↳ Mismatched due to spread (hitgroup: %s)',aimed_group)
shot.screen_subtitle_segments={
{text='↳ ',color={190,190,195}},
{text='Mismatched due to ',color={200,200,200}},
{text='spread',color={200,100,120}},
{text=' (hitgroup: ',color={200,200,200}},
{text=aimed_group,color={200,200,200}},
{text=')',color={200,200,200}}
}
else
shot.screen_subtitle=nil
shot.screen_subtitle_segments=nil
end

if health==0 then
shot.console_text=string.format("did -%d (%s) in %s (%d%%) to %s (%dms/%dt)",
damage,delta,group,math.max(0,round_signed(shot.hc)),name,ms,bt)
else
shot.console_text=string.format("did -%d (%s) in %s (%d%%) to %s (hp left: %d | %dms/%dt)",
damage,delta,group,math.max(0,round_signed(shot.hc)),name,health,ms,bt)
end
if console_line ~= nil then
msg=console_line
shot.screen_segments=nil
shot.modern_text=console_line
shot.modern_segments=nil
shot.screen_subtitle=nil
shot.screen_subtitle_segments=nil
end
event_logs.push(msg,'hit',shot)
end
local function on_aim_miss(e)
local name=safe_player_name(e.target)
local group=hitgroups[e.hitgroup] or 'generic'
local reason,console_line=reference_logger.missed(e)
local shot=take_shot(e) or {
hc=math.floor((e.hit_chance or 0)+0.5),
bt=0,
predicted_dmg=tonumber(e.damage) or 0,
predicted_hitgroup=tonumber(e.hitgroup) or 0
}
shot.event='Misses'
local bt=round_signed(shot.bt)
local ms=tick_to_ms(bt)
local shown_hc=math.max(0,round_signed(shot.hc))
local msg=string.format(
"Missed shot due to %s (hitchance %d%%)",
reason,shown_hc
)
shot.screen_segments={
{text='Missed shot due to ',color={215,215,218}},
{text=reason,color={200,100,120}},
{text=' (hitchance ',color={215,215,218}},
{text=tostring(shown_hc)..'%',color={200,100,120}},
{text=')',color={215,215,218}}
}

shot.modern_text=string.format('Missed shot due to %s (hitchance: %d%%)',reason,shown_hc)
shot.modern_segments={
{text='Missed shot due to ',color={200,200,200}},
{text=reason,color={200,100,120}},
{text=' (hitchance: ',color={200,200,200}},
{text=tostring(shown_hc)..'%',color={200,200,200}},
{text=')',color={200,200,200}}
}
shot.screen_subtitle=nil
shot.screen_subtitle_segments=nil

shot.console_text=string.format("missed shot due to %s (%d%%) (target: %s | group: %s | %dms/%dt)",
reason,math.max(0,round_signed(shot.hc)),name,group,ms,bt)
if console_line ~= nil then
msg=console_line
shot.screen_segments=nil
shot.modern_text=console_line
shot.modern_segments=nil
shot.screen_subtitle=nil
shot.screen_subtitle_segments=nil
end
event_logs.push(msg,'miss',shot)
end
local function on_player_hurt(e)
reference_logger.player_hurt(e)
local me=entity.get_local_player()
if me==nil or client.userid_to_entindex(e.attacker)~=me then return end
local victim=client.userid_to_entindex(e.userid)
if victim==nil or victim==0 or victim==me then return end
local action=weapon_actions[e.weapon]; if action==nil then return end
local name=entity.get_player_name(victim) or 'unknown'
local health=math.max(e.health or 0,0)
local is_grenade=e.weapon=='hegrenade' or e.weapon=='inferno'
local event_name=is_grenade and 'Grenades' or 'Damage'
local msg=string.format('%s %s for %d damage (%d health remaining)',action,name,e.dmg_health or 0,health)
event_logs.push(msg,'hit',{event=event_name,console_text=msg})
end
local function on_item_purchase(e)
local buyer=client.userid_to_entindex(e.userid); local me=entity.get_local_player()
if buyer==nil or buyer==0 or buyer==me or not entity.is_enemy(buyer) then return end
local msg=string.format('%s bought %s',entity.get_player_name(buyer) or 'unknown',pretty_weapon(e.weapon))
event_logs.push(msg,'info',{event='Purchases',console_text=msg})
end
local function alpha_byte(value) return math.max(0,math.min(255,math.floor(value+0.5))) end
local function has_custom_log_color() return true end
local function event_color(item, position)
local ok,r,g,b,a=pcall(ref.event_log_text_color.get,ref.event_log_text_color)
if not ok or type(r)~='number' then return 245,245,245 end
return r,g,b
end
local function ember_round_rect(x, y, width, height, radius, r, g, b, a)
radius = math.max(1, math.min(radius, math.floor(math.min(width, height) * 0.5)))
renderer.rectangle(x + radius, y, width - radius * 2, height, r, g, b, a)
renderer.rectangle(x, y + radius, width, height - radius * 2, r, g, b, a)
renderer.circle(x + radius, y + radius, r, g, b, a, radius, 0, 1)
renderer.circle(x + width - radius, y + radius, r, g, b, a, radius, 0, 1)
renderer.circle(x + radius, y + height - radius, r, g, b, a, radius, 0, 1)
renderer.circle(x + width - radius, y + height - radius, r, g, b, a, radius, 0, 1)
end
local function parse_log_segments(text)
local segments,position,accent={ },1,false
text=tostring(text or '')
while position<=#text do
local marker_start,marker_end,marker=text:find('/([vr])',position)
if marker_start==nil then
if position<=#text then segments[#segments+1]={text=text:sub(position),accent=accent} end
break
end
if marker_start>position then
segments[#segments+1]={text=text:sub(position,marker_start-1),accent=accent}
end
accent=marker=='v'
position=marker_end+1
end
return segments
end
local function segment_width(segments,flags)
local width=0
for i=1,#segments do width=width+renderer.measure_text(flags,segments[i].text) end
return width
end
local function reference_card_width(item)
local clean=strip_log_markup(item.text)
return math.max(118,renderer.measure_text('d',clean)+22)
end
local function draw_default(anchor_x,y,item,alpha,accent_r,accent_g,accent_b)
local clean=strip_log_markup(item.text)
local flags='d'
local text_width,text_height=renderer.measure_text(flags,clean)
local width=math.max(118,text_width+22)
local height=22
local radius=5
local scale=math.max(0,math.min(1,item.scale or 1))
local slide=math.floor((1-scale)*-8)
local x=math.floor(anchor_x+slide)
local glow=0.35

if glow>0 then
for n=3,1,-1 do
local ga=alpha_byte(alpha*glow*(0.010+n*0.006))
ember_round_rect(x-n,y-n,width+n*2,height+n*2,radius+n,accent_r,accent_g,accent_b,ga)
end
end

ember_round_rect(x+1,y+2,width,height,radius,0,0,0,alpha_byte(alpha*0.26))
ember_round_rect(x,y,width,height,radius,73,73,75,alpha_byte(alpha*0.72))
ember_round_rect(x+1,y+1,width-2,height-2,radius-1,8,8,9,alpha_byte(alpha*0.78))

local tx=x+11
local ty=y+math.floor((height-(text_height or 8))*0.5)-1
renderer.text(tx,ty,accent_r,accent_g,accent_b,alpha,flags,0,clean)
end
local function draw_mini(cx,y,item,alpha,accent_r,accent_g,accent_b)
local clean=strip_log_markup(item.text)
local prefix=get_log_prefix()..' · '; local full=prefix..clean; local width=renderer.measure_text('',full)
local x=math.floor(cx-width*0.5)
if has_custom_log_color() then
renderer.text(x,y,accent_r,accent_g,accent_b,alpha,'',0,prefix)
renderer.text(x+renderer.measure_text('',prefix),y,225,228,235,alpha,'',0,clean)
else
renderer.text(x,y,accent_r,accent_g,accent_b,alpha,'',0,full)
end
end
local modern_tex = { }
do
local ok_hit, hit_data = pcall(base64.decode, [==[iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAACXBIWXMAAA7DAAAOwwHHb6hkAAAAGXRFWHRTb2Z0d2FyZQB3d3cuaW5rc2NhcGUub3Jnm+48GgAAAupJREFUWIXFlk1IFVEUx/9PfJX2pRKkSYJSLoy0skWLdkUFQoUaURDtWuSqWrQoom0ELW1hQYuCPldKtAyiDPpGEjVbtOhDEiM/Mirfr8XM6HnzZt7cZ0UHDszM/d//+d9z751zUoD+pxXPY05a0npJ9ZLKJBVJGpM0LOmVpJ8FsQEungYOAN3ANPE2DfQA+4FiF26X4HuBoTxB42wY2P4nAkqAKzHkA8BT8/4CeBeBywCXgMWFCigHnoXIRoDTQI2PaTdj7f63BuAcMB6a+wBY6iqgFHgYIugClodwUQICXwFcD3H0RmUiSkCXmZQBjsZkKZ+AwI8DMwbXmSRglx80sBMxxK4CAhF2QTvjBKSAPgO+lYdUQJvBtiVgbxhsnx8rR8AeA5oAqhJI1wLffF+TgF3pcwY2ez0tqNsAcvYqxit9d8FeMPy3wwJKge8G0ORIWog3Gv7P+NsQDG4xgwP/IHjgH0ycemC2GNWa8jApaV+oZGQkPZb03rHE1Elqjvg+JqnKf26QNBQIWGZAzZJuRkwekbRaydWuXF5VXJKAWyh5pVSSZhLAklRI4+CCXSDN9QOjZuCNpFMhcEZSr9xq/RdJTZI2R4ydlZd6SZrypHqHY505HJM41vJ5+CcTp9HegiJgzAxu/QfBNxj+iWCRwRnISLpnUnXEIdWSt4Wubd1h83xX0i+7BQJ2GIXTQG3Ciqr9lH4EViVgK8nuEVqCMQtKkd2E9CSQthpsawL2msG+xNty2S2QvKtzUnNXqEXSsTwpLYp5DluHpIOhGJm5qLlqLxu1M8ChmFW59AMdZDckF8OYqEmlwHOyrRMoK0BANXA1xHEfWOQiIDg0/SGCUeAMUBcjIAVsAs4DU6G5j8jtKfMKEFBB9uGx9pbstvwJ0W05eG15SVwclx9IKzAYQ57PXgPbkvhd/2JpvL6vm9z0WhsH7gC7MVctn3tdSWGWlrRRUo2kCv/bV0mDkvol/SiEbD4C/qr9BmipUPGI4R90AAAAAElFTkSuQmCC]==])
if ok_hit and hit_data ~= nil then
local ok_tex, tex_hit = pcall(renderer.load_png, hit_data, 14, 14)
if ok_tex then modern_tex.hit = tex_hit end
end
local ok_miss, miss_data = pcall(base64.decode, [==[iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAACXBIWXMAAA7DAAAOwwHHb6hkAAAAGXRFWHRTb2Z0d2FyZQB3d3cuaW5rc2NhcGUub3Jnm+48GgAAAmhJREFUWIXFlz1rFFEUht/oBhNBNlgEBSEQrQRRgqawEAujBEIULO0sRQsrKwvBxspasLDxB1ioiUZBCGJCEAQjFnauxI9EE8WPFZPHYnbw7uy5d87GhbwwsMycc97n3r3nztwuQBupTRvqLqnSZny3pCONa5ekfklrkt5Lqkl6JGlG0qq7IuC5BoCbwArl+gRcB/o9tcsCehrF6g7jor4Bl4HN6wXYCTxbh3FRE0BfuwADQK0D5rleAdu9AL3AXAfNc00BFQ/A7UiBNXxr4Vfi2bUygEMNI8v8AjAC/EgYLAPDwJXI8zowmAKYipifD2KORyC+AAeDuKsRiFsxgN2RhJdk7RjGFiGK5gKqwDujXh3YZgFcjAAATJItzjA+/zvyaS+ap1r4tAVwL5EAcJ/WmRihdeR9wExJrRsWwHxJEtgz0c7IwzotAEuOxBSE1xzgRZ4Xvo57nO+vYUmDxv19kvY7a/TmP0KAD47EFUknJM0bz6YljUv66aizYAEsGIGhliUdkzQb3KuqeeYeSjrlgDABniYS8pHPFcwnJd1RMKWSHkg6WQLxzytYREcjC8bT56l9wtIejC6oYO9ctTCBrM9njbgJmveJIeCzEfc8BC220rkI8dsGRFmr5TNxAFiMxIylALqBNwkIz3fCE+yRA0wX/MzvgSHgu8OoXS3R/FdGAQSc6bD5H2DU8ooBCDhL+uvGq6/AeMwnBSDgMHZnePUa2JvyKAMQsBW4RHxhWfrYyNlSVr8L3IfTqqRRSWPKjmY7lB3VJOm3sqPZY0l3Gzuk553QFkBLrrKz4aqkxXUX+Q+AjugvmL78GhUfoesAAAAASUVORK5CYII=]==])
if ok_miss and miss_data ~= nil then
local ok_tex, tex_miss = pcall(renderer.load_png, miss_data, 22, 22)
if ok_tex then modern_tex.miss = tex_miss end
end
end

local SLOG = {
max_entries = 5,
row_h       = 26,
row_h_sub   = 39,
gap_y       = 4,
pad_x       = 10,
icon_sz     = 14,
icon_gap    = 6,
radius      = 8,
min_w       = 160,
}

local function modern_render_rec(x,y,w,h,radius,color)
radius=math.min(w/2,h/2,radius)
local r,g,b,a=color[1],color[2],color[3],color[4]
renderer.rectangle(x,y+radius,w,h-radius*2,r,g,b,a)
renderer.rectangle(x+radius,y,w-radius*2,radius,r,g,b,a)
renderer.rectangle(x+radius,y+h-radius,w-radius*2,radius,r,g,b,a)
renderer.circle(x+radius,y+radius,r,g,b,a,radius,180,0.25)
renderer.circle(x+w-radius,y+radius,r,g,b,a,radius,-90,0.25)
renderer.circle(x+radius,y+h-radius,r,g,b,a,radius,90,0.25)
renderer.circle(x+w-radius,y+h-radius,r,g,b,a,radius,0,0.25)
end

local function modern_draw_bg(x,y,w,h,rad,alpha)
local mul=math.max(0,math.min(1,(tonumber(alpha) or 255)/255))
modern_render_rec(x,y,w,h,rad or math.floor(h/2),{10,10,10,math.floor(150*mul)})
end

local function modern_draw_inner_corner(x,y,w,h,rad,accent,alpha)
local r,g,b=accent[1],accent[2],accent[3]
rad=rad or math.floor(h/2)
if rad>h/2 then rad=math.floor(h/2) end
if rad<=0 or w<=0 or h<=0 then return end
for i=0,rad*2-1 do
local dy=i-rad+0.5
local abs_dy=math.abs(dy)
if abs_dy<=rad then
local inset=rad-math.sqrt(math.max(0,rad*rad-dy*dy))
local row_alpha=alpha*(1-abs_dy/rad)
local base_x=x+inset
local lw=w-inset
if lw>0 then
for num=1,3 do
local ga=alpha*(0.01/lw)
if ga>0 then renderer.rectangle(base_x-num-2,y+i-num,lw+num*2+2,1+num*2,r,g,b,ga) end
end
renderer.rectangle(base_x,y+i,lw,1,r,g,b,row_alpha)
end
end
end
end

local function modern_measure_segments(segments,flags)
if type(segments)~='table' or #segments==0 then return 0 end
local width=0
for i=1,#segments do
width=width+(renderer.measure_text(flags,tostring(segments[i].text or '')) or 0)
end
return width
end
local function modern_main_width(item)
if type(item.modern_segments)=='table' and #item.modern_segments>0 then return modern_measure_segments(item.modern_segments,'b') end
return renderer.measure_text('b',tostring(item.modern_text or strip_log_markup(item.text))) or 0
end
local function modern_subtitle_width(item)
if type(item.subtitle_segments)=='table' and #item.subtitle_segments>0 then return modern_measure_segments(item.subtitle_segments,'b') end
if item.subtitle~=nil and tostring(item.subtitle)~='' then return renderer.measure_text('b',tostring(item.subtitle)) or 0 end
return 0
end
local function modern_has_subtitle(item) return modern_subtitle_width(item)>0 end
local function modern_card_height(item) return modern_has_subtitle(item) and SLOG.row_h_sub or SLOG.row_h end
local function modern_card_width(item)
return math.max(SLOG.min_w,SLOG.pad_x+SLOG.icon_sz+SLOG.icon_gap+math.max(modern_main_width(item),modern_subtitle_width(item))+SLOG.pad_x)
end
local _,modern_text_height=renderer.measure_text('b','0')
modern_text_height=modern_text_height or 8
local function draw_modern_segments(x,y,segments,alpha,flags,fallback)
local cursor=x
for i=1,#segments do
local segment=segments[i]
local value=tostring(segment.text or '')
local color=segment.color or fallback
renderer.text(cursor,y,color[1] or fallback[1],color[2] or fallback[2],color[3] or fallback[3],alpha,flags,0,value)
cursor=cursor+(renderer.measure_text(flags,value) or 0)
end
end
local function draw_modern(anchor_x,y,item,alpha,accent_r,accent_g,accent_b)
local row_w=modern_card_width(item)
local row_h=modern_card_height(item)
local x=math.floor(anchor_x)
local accent=item.kind=='miss' and {200,100,120} or {accent_r,accent_g,accent_b}
local has_sub=modern_has_subtitle(item)
modern_draw_bg(x,y,row_w,row_h,SLOG.radius,alpha)
modern_draw_inner_corner(x+1,y,3,row_h,row_h/2,accent,alpha)
local ico_x=x+SLOG.pad_x
local ico_y=y+math.floor((row_h-SLOG.icon_sz)/2)
if item.icon_type=='hit' and modern_tex.hit~=nil then
renderer.texture(modern_tex.hit,ico_x,ico_y,14,14,accent[1],accent[2],accent[3],alpha,'f')
elseif item.icon_type=='miss' and modern_tex.miss~=nil then
renderer.texture(modern_tex.miss,ico_x-4,ico_y-4,22,22,200,100,100,alpha,'f')
end
local tx=x+SLOG.pad_x+SLOG.icon_sz+SLOG.icon_gap
local main_y=has_sub and (y+5) or (y+math.floor((row_h-modern_text_height)/2)-3)
local segs=item.modern_segments or item.segments
if type(segs)=='table' and #segs>0 then draw_modern_segments(tx,main_y,segs,alpha,'b',{200,200,200})
else renderer.text(tx,main_y,200,200,200,alpha,'b',0,tostring(item.modern_text or item.text or '')) end
if has_sub then
local sub_y=y+20
local subs=item.subtitle_segments
if type(subs)=='table' and #subs>0 then draw_modern_segments(tx,sub_y,subs,alpha,'b',{200,200,200})
else renderer.text(tx,sub_y,200,200,200,alpha,'b',0,tostring(item.subtitle or '')) end
end
end
local function on_paint()
if not ref.event_logs:get() then return end
local now,ft=globals.realtime(),globals.frametime(); local sw,sh=client.screen_size(); local style=ref.event_log_style:get()
local duration=5.0

if not ref.event_log_show_screen:get() then return end
for i=#entries,1,-1 do
local item=entries[i]; local age=now-item.time; local alive=age<duration
local target=alive and 255 or math.max(0,255*(1-(age-duration)/fade_time))
local target_scale=alive and 1 or 0
item.alpha=helper_motion.approach(item.alpha,target,14)
item.scale=helper_motion.approach(item.scale or 0,target_scale,12)
item.y=helper_motion.approach(item.y,0,12)
if age>duration+fade_time and item.alpha<=1 and item.scale<=0.01 then table.remove(entries,i) end
end
local display=entries
if ui.is_menu_open() then
local pr,pg,pb,pa=control_color(ref.event_log_text_color,210,140,255,255)
display={
{
text='Missed shot due to spread (hitchance: 67%)',
modern_text='Missed shot due to spread (hitchance: 67%)',
modern_segments={{text='Missed shot due to ',color={200,200,200}},{text='spread',color={200,100,120}},{text=' (hitchance: ',color={200,200,200}},{text='67%',color={200,200,200}},{text=')',color={200,200,200}}},
kind='miss',icon_type='miss',color={200,100,120},time=now,alpha=255,scale=1,y=0
},
{
text='Hit demyaha in the head for 100 damage (0 health remaining)',
modern_text='Hit demyaha in the head for 100 damage (0 health remaining)',
modern_segments={{text='Hit ',color={200,200,200}},{text='demyaha',color={pr,pg,pb}},{text=' in the ',color={200,200,200}},{text='head',color={pr,pg,pb}},{text=' for ',color={200,200,200}},{text='100',color={pr,pg,pb}},{text=' damage (',color={200,200,200}},{text='0',color={pr,pg,pb}},{text=' health remaining)',color={200,200,200}}},
kind='hit',icon_type='hit',color={pr,pg,pb},time=now,alpha=255,scale=1,y=0
},
{
text='Hit lordmouse in the neck for 67 damage (33 health remaining)',
modern_text='Hit lordmouse in the neck for 67 damage (33 health remaining)',
modern_segments={{text='Hit ',color={200,200,200}},{text='lordmouse',color={pr,pg,pb}},{text=' in the ',color={200,200,200}},{text='neck',color={pr,pg,pb}},{text=' for ',color={200,200,200}},{text='67',color={pr,pg,pb}},{text=' damage (',color={200,200,200}},{text='33',color={pr,pg,pb}},{text=' health remaining)',color={200,200,200}}},
subtitle='↳ Mismatched due to spread (hitgroup: head)',
subtitle_segments={{text='↳ ',color={190,190,195}},{text='Mismatched due to ',color={200,200,200}},{text='spread',color={200,100,120}},{text=' (hitgroup: ',color={200,200,200}},{text='head',color={200,200,200}},{text=')',color={200,200,200}}},
kind='hit',icon_type='hit',color={pr,pg,pb},time=now,alpha=255,scale=1,y=0
}
}
end
local row=style=='Mini' and 15 or 25
local card_height=style=='Mini' and 12 or 22
local stack_width=112
for i=1,#display do
local item=display[i]
local item_width
if style=='Mini' then
item_width=renderer.measure_text('',strip_log_markup(item.text))
elseif style=='Modern' then
item_width=modern_card_width(item)
else
item_width=reference_card_width(item)
end
if item_width>stack_width then stack_width=item_width end
end

local stack_height
if style=='Modern' then
stack_height=0
for i=1,#display do
stack_height=stack_height+modern_card_height(display[i])
if i<#display then stack_height=stack_height+SLOG.gap_y end
end
stack_height=math.max(SLOG.row_h,stack_height)
else
stack_height=math.max(card_height,(#display-1)*row+card_height)
end

local default_x=24
local default_y=34
local x,y=drag_system.update('event_logs_console_top_left_v3',default_x,default_y,stack_width,stack_height)
local modern_y=0

for i=1,#display do
local item=display[i]; local alpha=alpha_byte(item.alpha or 225); local cr,cg,cb=event_color(item,#display>1 and (i-1)/(#display-1) or 0)
local yy
if style=='Modern' then
yy=y+modern_y+math.floor(item.y or 0)
else
yy=y+(i-1)*row+math.floor(item.y or 0)
end

if style=='Mini' then
local clean=strip_log_markup(item.text)
local mini_width=renderer.measure_text('',clean)
draw_mini(x+mini_width*0.5,yy,item,alpha,cr,cg,cb)
elseif style=='Modern' then
draw_modern(x,yy,item,alpha,cr,cg,cb)
modern_y=modern_y+modern_card_height(item)+SLOG.gap_y
else
draw_default(x,yy,item,alpha,cr,cg,cb)
end
end
end
__aetheryx_runtime.set('aim_fire',on_aim_fire)
__aetheryx_runtime.set('aim_hit',on_aim_hit)
__aetheryx_runtime.set('aim_miss',on_aim_miss)
__aetheryx_runtime.set('bullet_impact',reference_logger.bullet_impact)
__aetheryx_runtime.set('net_update_start',reference_logger.net_update_start)
__aetheryx_runtime.set('player_hurt',on_player_hurt)
__aetheryx_runtime.set('item_purchase',on_item_purchase)
__aetheryx_runtime.set('paint',on_paint)
end


-- Aetheryx HUD - literal source visual source port -------------------------
-- Recovered from source factories:
--   main[3]   render_rect
--   main[30]  blur queue
--   main[46]  blur dispatcher
--   main[77]  shadow queue
--   main[87]  watermark item builder
--   main[90]  watermark renderer
--   main[97]  hotkeys renderer
--   main[273] Panorama blur/shadow backend
--
-- Only Aetheryx data bindings and the brand text differ from source.
local aetheryx_glass_hud do
local ref = menu_elements.other.visual

local RADIUS = 12
local DEFAULT_H = 24
local HOTKEY_BASE_W = 124
local ROW_STEP = 16
local ANIM_TIME = 0.15

local PANORAMA_FX_SOURCE = [====[
return {
            new: function() {
                let ctx = $.GetContextPanel();
                let root = null, blur_layer = null, shadow_layer = null;
                let shadow_pool = [], shadow_used = 0;
                let blur_pool = [], blur_used = 0;

                let make_layer = function() {
                    let l = $.CreatePanel('Panel', root, '');
                    l.style.width = '100%';
                    l.style.height = '100%';
                    return l;
                };

                // The host panel (especially the loading screen) can be destroyed by
                // the game, which deletes root and its layers out from under us. Rebuild
                // the hierarchy whenever that happens, and reset the pools so we never
                // reference panels that were children of the deleted root.
                let ensure = function() {
                    if (root && root.IsValid()) return true;
                    ctx = $.GetContextPanel();
                    if (!ctx || !ctx.IsValid()) return false;
                    root = $.CreatePanel('Panel', ctx, '');
                    root.style.width = '100%';
                    root.style.height = '100%';
                    root.hittest = false;
                    root.hittestchildren = false;
                    blur_layer = make_layer();
                    shadow_layer = make_layer();
                    shadow_pool = []; shadow_used = 0;
                    blur_pool = []; blur_used = 0;
                    return true;
                };

                let blur_layout = `<root><styles><include src='file://{resources}/styles/csgostyles.css' /><include src='file://{resources}/styles/hud/hud.css' /></styles><CSGOBlurTarget style='-s2-mix-blend-mode:normal;'><CSGOBackbufferImagePanel class='full-width full-height' /></CSGOBlurTarget></root>`;

                return {
                    is_active: function() {
                        if (!ensure()) return false;
                        return ctx.actuallayoutwidth > 0 && ctx.actuallayoutheight > 0;
                    },

                    set_shadow: function(x, y, w, h, r, g, b, a, blur, spread, radius) {
                        let p = shadow_pool[shadow_used];
                        if (!p) {
                            p = shadow_pool[shadow_used] = $.CreatePanel('Panel', shadow_layer, '');
                            p.hittest = false;
                            p._s = {};
                        }
                        let s = p._s;
                        // contentwidth/height share the Lua renderer's pixel space, but Panorama
                        // 'px' style units are scaled by uiscale and misbehave on non-16:9 aspects.
                        // Position/size via percentages (geometric -> scale/aspect independent) so
                        // the shadow lines up with the renderer on any resolution.
                        let cw = ctx.contentwidth, ch = ctx.contentheight;
                        if (cw <= 0 || ch <= 0) return;
                        if (s.x!==x||s.y!==y||s.w!==w||s.h!==h||s.cw!==cw||s.ch!==ch||s.radius!==radius) {
                            p.style.position = `${x/cw*100}% ${y/ch*100}% 0px`;
                            p.style.width  = `${w/cw*100}%`;
                            p.style.height = `${h/ch*100}%`;
                            p.style.borderRadius = `${w>0?radius/w*100:0}% / ${h>0?radius/h*100:0}%`;
                            s.x=x;s.y=y;s.w=w;s.h=h;s.cw=cw;s.ch=ch;s.radius=radius;
                        }
                        // boxShadow blur/spread can only be px (still uiscale-relative); positioning
                        // above is what fixes the alignment, the glow just scales with the UI.
                        if (s.r !== r || s.g !== g || s.b !== b || s.a !== a || s.blur !== blur || s.spread !== spread) {
                            p.style.boxShadow = `0px 0px ${blur}px ${spread}px rgba(${r},${g},${b},${a/255})`;
                            s.r = r; s.g = g; s.b = b; s.a = a; s.blur = blur; s.spread = spread;
                        }
                        if (!s.visible) { p.visible = true; s.visible = true; }
                        shadow_used++;
                    },

                    set_blur: function(x, y, w, h, factor, alpha, radius) {
                        let p = blur_pool[blur_used];
                        if (!p) {
                            p = blur_pool[blur_used] = $.CreatePanel('Panel', blur_layer, '');
                            p.hittest = false;
                            p.style.overflow = 'clip clip';
                            p.BLoadLayoutFromString(blur_layout, false, false);
                            p._s = {};
                            p._t = p.GetChild(0);
                        }
                        let s = p._s, t = p._t;
                        // contentwidth/height share the Lua renderer's pixel space, but Panorama
                        // 'px' style units get multiplied by uiscale (and break on non-16:9). Place
                        // everything in percentages so the blur stays pinned to the renderer on any
                        // resolution / UI scale / aspect ratio. The backbuffer child (t) must cover
                        // the whole screen, expressed as a percentage of the region panel (p).
                        let cw = ctx.contentwidth, ch = ctx.contentheight;
                        if (cw <= 0 || ch <= 0) return;
                        if (s.x!==x||s.y!==y||s.w!==w||s.h!==h||s.cw!==cw||s.ch!==ch||s.radius!==radius) {
                            p.style.position = `${x/cw*100}% ${y/ch*100}% 0px`;
                            p.style.width  = `${w/cw*100}%`;
                            p.style.height = `${h/ch*100}%`;
                            p.style.borderRadius = `${w>0?radius/w*100:0}% / ${h>0?radius/h*100:0}%`;
                            t.style.width  = `${w>0?cw/w*100:100}%`;
                            t.style.height = `${h>0?ch/h*100:100}%`;
                            t.style.position = `${w>0?-x/w*100:0}% ${h>0?-y/h*100:0}% 0px`;
                            s.x=x;s.y=y;s.w=w;s.h=h;s.cw=cw;s.ch=ch;s.radius=radius;
                        }
                        if (s.factor !== factor) { t.style.blur = `fastgaussian(${factor},${factor},${factor})`; s.factor = factor; }
                        if (s.alpha !== alpha) { t.style.opacity = alpha.toFixed(4); s.alpha = alpha; }
                        if (!s.visible) { p.visible = true; s.visible = true; }
                        blur_used++;
                    },

                    flush: function() {
                        for (let i = shadow_used; i < shadow_pool.length; i++) {
                            let p = shadow_pool[i];
                            if (p._s.visible) { p.visible = false; p._s.visible = false; }
                        }
                        for (let i = blur_used; i < blur_pool.length; i++) {
                            let p = blur_pool[i];
                            if (p._s.visible) { p.visible = false; p._s.visible = false; }
                        }
                        shadow_used = 0;
                        blur_used = 0;
                    },

                    release: function() {
                        if (root && root.IsValid()) {
                            root.RemoveAndDeleteChildren();
                            root.DeleteAsync(0);
                        }
                        root = null;
                    }
                }
            }
        }
]====]

local SVG_SOURCE = {
    code = [====[
<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                <path fill="none" d="M18 16L22 12L18 8" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M6 8L2 12L6 16" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M14.5 4L9.5 20" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
]====],
    person = [====[
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
                <path fill="none" d="M12 13C14.7614 13 17 10.7614 17 8C17 5.23858 14.7614 3 12 3C9.23858 3 7 5.23858 7 8C7 10.7614 9.23858 13 12 13Z" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M20 21C20 18.8783 19.1571 16.8434 17.6569 15.3431C16.1566 13.8429 14.1217 13 12 13C9.87827 13 7.84344 13.8429 6.34315 15.3431C4.84285 16.8434 4 18.8783 4 21" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
]====],
    satellite = [====[
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
                <path fill="none" d="M13.5 6.49999L10.352 3.35199C10.126 3.12605 9.81954 2.99911 9.49999 2.99911C9.18043 2.99911 8.87396 3.12605 8.64799 3.35199L6.35199 5.64799C6.12605 5.87396 5.99911 6.18043 5.99911 6.49999C5.99911 6.81954 6.12605 7.12601 6.35199 7.35199L9.49999 10.5" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M16.5 7.5L19 5" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M17.5 10.5L20.648 13.648C20.8739 13.874 21.0009 14.1804 21.0009 14.5C21.0009 14.8196 20.8739 15.126 20.648 15.352L18.352 17.648C18.126 17.8739 17.8196 18.0009 17.5 18.0009C17.1804 18.0009 16.874 17.8739 16.648 17.648L13.5 14.5" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M9 21C9 19.4087 8.36786 17.8826 7.24264 16.7574C6.11742 15.6321 4.5913 15 3 15" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M9.35202 10.648C9.12608 10.874 8.99915 11.1804 8.99915 11.5C8.99915 11.8195 9.12608 12.126 9.35202 12.352L11.648 14.648C11.874 14.8739 12.1805 15.0009 12.5 15.0009C12.8196 15.0009 13.126 14.8739 13.352 14.648L17.648 10.352C17.874 10.126 18.0009 9.81954 18.0009 9.49999C18.0009 9.18043 17.874 8.87396 17.648 8.64799L15.352 6.35199C15.126 6.12605 14.8196 5.99911 14.5 5.99911C14.1805 5.99911 13.874 6.12605 13.648 6.35199L9.35202 10.648Z" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
]====],
    server = [====[
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
                <path fill="none" d="M12 8C16.9706 8 21 6.65685 21 5C21 3.34315 16.9706 2 12 2C7.02944 2 3 3.34315 3 5C3 6.65685 7.02944 8 12 8Z" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M3 5V19C3 19.7956 3.94821 20.5587 5.63604 21.1213C7.32387 21.6839 9.61305 22 12 22C14.3869 22 16.6761 21.6839 18.364 21.1213C20.0518 20.5587 21 19.7956 21 19V5" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M3 12C3 12.7956 3.94821 13.5587 5.63604 14.1213C7.32387 14.6839 9.61305 15 12 15C14.3869 15 16.6761 14.6839 18.364 14.1213C20.0518 13.5587 21 12.7956 21 12" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
]====],
    frames = [====[
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
                <path fill="none" d="M2 7V17" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M6 5V19" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M20 3H12C10.8954 3 10 3.89543 10 5V19C10 20.1046 10.8954 21 12 21H20C21.1046 21 22 20.1046 22 19V5C22 3.89543 21.1046 3 20 3Z" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
]====],
    time = [====[
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
                <path fill="none" d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M12 6V12L16 14" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
]====],
    brackets = [====[
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
                <path fill="none" d="M8 3H7C6.46957 3 5.96086 3.21071 5.58579 3.58579C5.21071 3.96086 5 4.46957 5 5V10C5 10.5304 4.78929 11.0391 4.41421 11.4142C4.03914 11.7893 3.53043 12 3 12C3.53043 12 4.03914 12.2107 4.41421 12.5858C4.78929 12.9609 5 13.4696 5 14V19C5 20.1 5.9 21 7 21H8" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                <path fill="none" d="M16 21H17C17.5304 21 18.0391 20.7893 18.4142 20.4142C18.7893 20.0391 19 19.5304 19 19V14C19 12.9 19.9 12 21 12C20.4696 12 19.9609 11.7893 19.5858 11.4142C19.2107 11.0391 19 10.5304 19 10V5C19 4.46957 18.7893 3.96086 18.4142 3.58579C18.0391 3.21071 17.5304 3 17 3H16" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
]====]
}

local ICON_SIZE = {
    code={12,12}, person={12,12}, satellite={12,12}, server={12,12},
    frames={12,12}, time={12,12}, brackets={11,11}
}

local function clamp(v, a, b)
    return math.max(a, math.min(b, v))
end

-- source ease_in_out is cubic-bezier(0.42, 0, 0.58, 1).
local function cubic_bezier_1d(t, p1, p2)
    local u = 1 - t
    return 3*u*u*t*p1 + 3*u*t*t*p2 + t*t*t
end

local function cubic_bezier_ease(x, x1, y1, x2, y2)
    x = clamp(x, 0, 1)
    local t = x
    for _ = 1, 6 do
        local u = 1 - t
        local bx = 3*u*u*t*x1 + 3*u*t*t*x2 + t*t*t
        local dx = 3*u*u*x1 + 6*u*t*(x2-x1) + 3*t*t*(1-x2)
        if math.abs(dx) < 0.00001 then break end
        t = clamp(t - (bx - x) / dx, 0, 1)
    end
    return cubic_bezier_1d(t, y1, y2)
end

local function ease_in_out(t)
    return cubic_bezier_ease(t, 0.42, 0, 0.58, 1)
end

local function new_anim(initial)
    return {
        value = initial or 0,
        from = initial or 0,
        to = initial or 0,
        time = 0,
        active = false
    }
end

local function animate(anim, target)
    if target ~= anim.to then
        anim.from = anim.value
        anim.to = target
        anim.time = 0
        anim.active = true
    end

    if anim.active then
        anim.time = math.min(anim.time + (tonumber(globals.frametime()) or 0), ANIM_TIME)
        local t = ANIM_TIME > 0 and anim.time / ANIM_TIME or 1
        local e = ease_in_out(t)
        anim.value = anim.from + (anim.to - anim.from) * e
        if t >= 1 then
            anim.value = anim.to
            anim.active = false
        end
    end

    return anim.value
end

local glass_fx = { instances = {} }

do
    local panels = {"CSGOHud", "CSGOMainMenu", "CSGOLoadingScreen"}

    for i = 1, #panels do
        local ok_loader, loader = pcall(panorama.loadstring, PANORAMA_FX_SOURCE, panels[i])
        if ok_loader and loader ~= nil then
            local ok_module, module = pcall(loader)
            if ok_module and module ~= nil and module.new ~= nil then
                local ok_instance, instance = pcall(module.new)
                if ok_instance and instance ~= nil then
                    glass_fx.instances[#glass_fx.instances + 1] = instance
                end
            end
        end
    end
end

local function active_fx()
    for i = 1, #glass_fx.instances do
        local instance = glass_fx.instances[i]
        local ok, active = pcall(instance.is_active)
        if ok and active then
            return instance
        end
    end
end

local function fx_blur(x, y, w, h, alpha, radius)
    local instance = active_fx()
    if instance ~= nil then
        pcall(instance.set_blur, x, y, w, h, 2.5, clamp(alpha or 1, 0, 1), radius or 0)
    end
end

local function fx_shadow(x, y, w, h, r, g, b, a, blur, spread, radius)
    local instance = active_fx()
    if instance ~= nil then
        pcall(instance.set_shadow, x, y, w, h, r, g, b, a, blur or 0, spread or 0, radius or 0)
    end
end

local function fx_flush()
    local instance = active_fx()
    if instance ~= nil then
        pcall(instance.flush)
    end
end

local function fx_release()
    for i = 1, #glass_fx.instances do
        local instance = glass_fx.instances[i]
        if instance ~= nil and instance.release ~= nil then
            pcall(instance.release)
        end
    end
end

local icons = {}
for name, svg in pairs(SVG_SOURCE) do
    local size = ICON_SIZE[name]
    local ok, texture = pcall(renderer.load_svg, svg, size[1], size[2])
    if ok then
        icons[name] = { texture=texture, w=size[1], h=size[2] }
    end
end

local function render_icon(icon, x, y, r, g, b, a)
    if icon == nil or icon.texture == nil then return end
    renderer.texture(icon.texture, x, y, icon.w, icon.h, r, g, b, a)
end

local function accent()
    local r, g, b, a = visual_colors.unpack(nil, nil, 1)
    return r or 255, g or 255, b or 255, a or 255
end

local function text_width(value)
    local w = renderer.measure_text(nil, value or "")
    return tonumber(w) or 0
end

-- Literal translation of source factory main[3].
local function glass_render_rect(x, y, w, h, r, g, b, alpha)
    h = h or DEFAULT_H
    alpha = alpha or 1

    local radius = RADIUS
    local middle_h = h - radius * 2

    -- main[46] -> custom Panorama blur, factor 2.5.
    fx_blur(x, y, w, h, alpha, radius)

    local cx = x + radius
    local middle_w = w - radius * 2

    -- Disabled the narrow Panorama shadow source strip here.
    -- With a bright Aetheryx accent it becomes a visible horizontal line
    -- through the middle of Watermark / Hotkeys. Blur + original body/edges remain.

    if middle_h <= 0 then
        renderer.circle(cx, y + radius, 150,150,150, 40*alpha, radius, 180, 0.5)
        renderer.circle(cx + middle_w, y + radius, 150,150,150, 40*alpha, radius, 0, 0.5)

        renderer.circle_outline(cx, y + radius, 200,200,200, 20*alpha, radius, 90, 0.5, 1)
        renderer.circle_outline(cx + middle_w, y + radius, 200,200,200, 20*alpha, radius, 270, 0.5, 1)
    else
        renderer.circle(cx, y + radius, 150,150,150, 40*alpha, radius, 180, 0.25)
        renderer.circle(cx + middle_w, y + radius, 150,150,150, 40*alpha, radius, 90, 0.25)
        renderer.circle(cx, y + h - radius, 150,150,150, 40*alpha, radius, 270, 0.25)
        renderer.circle(cx + middle_w, y + h - radius, 150,150,150, 40*alpha, radius, 0, 0.25)

        renderer.circle_outline(cx, y + radius, 200,200,200, 20*alpha, radius, 180, 0.25, 1)
        renderer.circle_outline(cx + middle_w, y + radius, 200,200,200, 20*alpha, radius, 270, 0.25, 1)
        renderer.circle_outline(cx, y + h - radius, 200,200,200, 20*alpha, radius, 90, 0.25, 1)
        renderer.circle_outline(cx + middle_w, y + h - radius, 200,200,200, 20*alpha, radius, 0, 0.25, 1)

        renderer.rectangle(cx - radius, y + radius, radius, middle_h, 150,150,150, 40*alpha)
        renderer.rectangle(cx + middle_w, y + radius, radius, middle_h, 150,150,150, 40*alpha)
        renderer.rectangle(cx - radius, y + radius, 1, middle_h, 150,150,150, 40*alpha)
        renderer.rectangle(cx + middle_w + radius - 1, y + radius, 1, middle_h, 150,150,150, 40*alpha)
    end

    renderer.rectangle(cx, y, middle_w, h, 150,150,150, 40*alpha)
    renderer.rectangle(cx, y + h - 1, middle_w, 1, 200,200,200, 20*alpha)
    renderer.rectangle(cx, y, middle_w, 1, 200,200,200, 20*alpha)
end

local function element_enabled(name)
    if ref.glass_hud == nil or not ref.glass_hud:get() then return false end
    local selected = ref.glass_hud_elements:get()
    if type(selected) ~= "table" then return false end
    for i = 1, #selected do
        if selected[i] == name then return true end
    end
    return false
end

-- source-style Aetheryx wordmark ------------------------------------------
-- source factory main[4] draws one SVG glyph at a time.
local WORDMARK_SOURCE = {
    ["a"] = {w=8, h=14, advance=7.43000, source=[====[<svg width="8" height="14" viewBox="0 0 8 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M6.84242 8.4405 6.42634 8.845099999999999C5.95082 9.3075 5.78736 9.43755 5.65362 9.43755C5.53474 9.43755 5.44558 9.35085 5.44558 9.249699999999999C5.44558 8.9607 6.0697 6.475299999999999 6.76812 4.00435C6.8126999999999995 3.85985 6.82756 3.8309499999999996 6.85728 3.7009L6.75326 3.6575499999999996L5.8468 3.7586999999999993L5.80222 3.8020499999999995L5.6387599999999996 4.4956499999999995C5.51988 3.9609999999999994 5.08894 3.6575499999999996 4.44996 3.6575499999999996C2.4735799999999997 3.6575499999999996 0.2 6.28745 0.2 8.584999999999999C0.2 9.596499999999999 0.76468 10.18895 1.7157200000000001 10.18895C2.7559199999999997 10.18895 3.3949 9.7121 4.70258 7.920299999999999C4.3905199999999995 9.1052 4.3608 9.220799999999999 4.3608 9.582049999999999C4.3608 10.0011 4.53912 10.1745 4.9552 10.1745C5.5496 10.1745 5.9062399999999995 9.899949999999999 7.02074 8.584999999999999ZM4.53912 3.9754499999999995C5.04436 4.00435 5.37128 4.35115 5.37128 4.8568999999999996C5.37128 6.0706999999999995 4.61342 7.775799999999999 3.60294 8.845099999999999C3.2462999999999997 9.235249999999999 2.74106 9.4809 2.31012 9.4809C1.77516 9.4809 1.4482400000000002 9.0763 1.4482400000000002 8.4116C1.4482400000000002 7.602399999999999 1.9980599999999997 6.142949999999999 2.6519 5.2326C3.2462999999999997 4.3945 3.9298599999999997 3.9320999999999993 4.53912 3.9754499999999995Z" fill="white"/></svg>]====]},
    ["e"] = {w=7, h=14, advance=6.59784, source=[====[<svg width="7" height="14" viewBox="0 0 7 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M5.059220000000001 8.45495C3.9892999999999996 9.3075 3.5286399999999998 9.538699999999999 2.8748 9.538699999999999C2.04264 9.538699999999999 1.49282 9.0185 1.49282 8.223749999999999C1.49282 8.007 1.5225399999999998 7.8046999999999995 1.64142 7.3423L2.0574999999999997 7.2844999999999995C4.2865 6.98105 5.8616600000000005 5.8828499999999995 5.8616600000000005 4.640149999999999C5.8616600000000005 4.03325 5.41586 3.6575499999999996 4.67286 3.6575499999999996C2.53302 3.6575499999999996 0.2 6.027349999999999 0.2 8.209299999999999C0.2 9.37975 1.00244 10.18895 2.16152 10.18895C3.21658 10.18895 4.3608 9.596499999999999 5.23754 8.62835ZM1.9980599999999997 6.388599999999999C2.5033 5.10255 3.60294 3.9898999999999996 4.3608 3.9898999999999996C4.67286 3.9898999999999996 4.8809000000000005 4.20665 4.8809000000000005 4.55345C4.8809000000000005 5.001399999999999 4.59856 5.521599999999999 4.1379 5.9551C3.5880799999999997 6.460849999999999 3.0234 6.720949999999999 1.7454399999999999 7.0244Z" fill="white"/></svg>]====]},
    ["h"] = {w=8, h=14, advance=7.43000, source=[====[<svg width="8" height="14" viewBox="0 0 8 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M6.82756 8.33935C6.025119999999999 9.3075 5.8468 9.4809 5.609039999999999 9.4809C5.4753 9.4809 5.37128 9.3653 5.37128 9.220799999999999C5.37128 9.06185 5.609039999999999 8.165949999999999 5.86166 7.414549999999999C6.292599999999999 6.0706999999999995 6.57494 4.986949999999999 6.57494 4.625699999999999C6.57494 4.0477 6.173719999999999 3.6575499999999996 5.59418 3.6575499999999996C4.628279999999999 3.6575499999999996 3.57322 4.5968 2.19124 6.7065L3.97444 0.232899999999999L3.90014 0.1606500000000004C3.00854 0.36294999999999966 2.4290000000000003 0.4496500000000001 1.56712 0.5508000000000006V0.782L1.9534800000000003 0.76755C2.2952600000000003 0.7530999999999999 2.5627400000000002 0.9120499999999989 2.5627400000000002 1.1288C2.5627400000000002 1.3310999999999993 2.48844 1.6778999999999993 2.3547000000000002 2.0969499999999996C2.33984 2.12585 2.2804 2.32815 2.2061 2.6315999999999997L0.2 10.03H1.3145000000000002C1.9089 7.8046999999999995 2.10208 7.3134 2.69648 6.43195C3.4692000000000003 5.2904 4.47968 4.3945 4.9997799999999994 4.3945C5.2226799999999995 4.3945 5.4158599999999995 4.5679 5.4158599999999995 4.75575C5.4158599999999995 4.813549999999999 5.37128 5.001399999999999 5.31184 5.2326L4.49454 8.223749999999999C4.30136 8.931799999999999 4.19734 9.37975 4.19734 9.553149999999999C4.19734 9.928849999999999 4.44996 10.16005 4.86604 10.16005C5.609039999999999 10.16005 6.12914 9.7699 7.02074 8.512749999999999Z" fill="white"/></svg>]====]},
    ["r"] = {w=7, h=14, advance=5.78054, source=[====[<svg width="7" height="14" viewBox="0 0 7 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M1.32936 10.03C2.10208 7.559049999999999 2.3547 6.9666 3.0382599999999997 5.853949999999999C3.5435 5.04475 3.9447200000000002 4.5968 4.19734 4.5968C4.30136 4.5968 4.3608 4.654599999999999 4.4351 4.799099999999999C4.55398 5.04475 4.67286 5.117 4.97006 5.117C5.4158599999999995 5.117 5.65362 4.8568999999999996 5.65362 4.3945C5.65362 3.9609999999999994 5.37128 3.6575499999999996 4.9552 3.6575499999999996C4.61342 3.6575499999999996 4.2122 3.8743 3.8258399999999995 4.26445C3.21658 4.8858 2.6221799999999997 5.7238999999999995 2.38442 6.3019L2.17638 6.822099999999999L2.9639599999999997 3.68645L2.91938 3.6575499999999996C1.8346000000000002 3.8453999999999997 1.7008600000000003 3.8743 0.6160800000000002 4.0477V4.293349999999999C0.9430000000000001 4.23555 1.00244 4.2211 1.12132 4.2211C1.4482400000000002 4.2211 1.6414199999999999 4.3656 1.6414199999999999 4.625699999999999C1.6414199999999999 4.827999999999999 1.6414199999999999 4.827999999999999 1.4036600000000001 5.8106L0.2 10.03Z" fill="white"/></svg>]====]},
    ["t"] = {w=5, h=14, advance=4.13108, source=[====[<svg width="5" height="14" viewBox="0 0 5 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M4.04874 3.8453999999999997H2.8599400000000004L3.2760200000000004 2.35705C3.29088 2.32815 3.29088 2.29925 3.29088 2.2703499999999996C3.29088 2.18365 3.2611600000000003 2.1403 3.172 2.1403C3.08284 2.1403 3.03826 2.15475 2.9491 2.2703499999999996C2.3695600000000003 2.99285 1.44824 3.7298 0.97272 3.85985C0.6012200000000001 3.9754499999999995 0.49720000000000003 4.06215 0.49720000000000003 4.2211C0.49720000000000003 4.23555 0.49720000000000003 4.26445 0.51206 4.307799999999999H1.6117L0.5417799999999999 8.28155C0.51206 8.4116 0.49720000000000003 8.4694 0.4526200000000001 8.584999999999999C0.30402 9.06185 0.2 9.509799999999998 0.2 9.6543C0.2 9.957749999999999 0.51206 10.18895 0.9132799999999999 10.18895C1.59684 10.18895 2.0872200000000003 9.78435 3.0234 8.4405L2.83022 8.33935C2.1020800000000004 9.249699999999999 1.86432 9.4809 1.62656 9.4809C1.49282 9.4809 1.40366 9.37975 1.40366 9.191899999999999C1.40366 9.17745 1.40366 9.17745 1.41852 9.11965L2.7262000000000004 4.307799999999999H3.97444Z" fill="white"/></svg>]====]},
    ["x"] = {w=7, h=14, advance=6.59784, source=[====[<svg width="7" height="14" viewBox="0 0 7 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M6.57494 8.42605C6.456060000000001 8.556099999999999 6.38176 8.6428 6.24802 8.816199999999998C5.90624 9.249699999999999 5.727919999999999 9.3942 5.5496 9.3942C5.341559999999999 9.3942 5.20782 9.206349999999999 5.1038 8.80175C5.05922 8.6428 5.05922 8.6139 5.044359999999999 8.570549999999999C4.67286 7.0966499999999995 4.509399999999999 6.43195 4.509399999999999 6.215199999999999C5.178100000000001 5.0881 5.6982 4.466749999999999 5.965680000000001 4.466749999999999C6.05484 4.466749999999999 6.18858 4.5100999999999996 6.3223199999999995 4.58235C6.500640000000001 4.6834999999999996 6.604660000000001 4.7124 6.7384 4.7124C7.0356000000000005 4.7124 7.243639999999999 4.4956499999999995 7.243639999999999 4.1922C7.243639999999999 3.8743 6.991020000000001 3.6575499999999996 6.63438 3.6575499999999996C5.9805399999999995 3.6575499999999996 5.430720000000001 4.17775 4.39052 5.7238999999999995L4.22706 4.92915C4.01902 3.9465499999999993 3.85556 3.6575499999999996 3.45434 3.6575499999999996C3.11256 3.6575499999999996 2.6370400000000003 3.7731499999999993 1.7157200000000001 4.0766C1.62656 4.105499999999999 1.62656 4.105499999999999 1.55226 4.134399999999999L1.6117000000000001 4.35115C2.19124 4.20665 2.29526 4.1922 2.44386 4.1922C2.81536 4.1922 2.90452 4.3222499999999995 3.11256 5.1892499999999995L3.5435 6.9666L2.32498 8.65725C2.0129200000000003 9.09075 1.73058 9.35085 1.56712 9.35085C1.47796 9.35085 1.32936 9.3075 1.18076 9.220799999999999C0.9875800000000001 9.11965 0.8389800000000001 9.0763 0.7052400000000001 9.0763C0.40804000000000007 9.0763 0.20000000000000007 9.29305 0.20000000000000007 9.582049999999999C0.20000000000000007 9.957749999999999 0.4823400000000001 10.18895 0.9430000000000001 10.18895C1.4036600000000001 10.18895 1.5819800000000002 10.0589 2.32498 9.191899999999999C2.7262 8.71505 3.0531200000000003 8.28155 3.66238 7.4868L4.10818 9.220799999999999C4.301360000000001 9.972199999999999 4.494540000000001 10.18895 4.97006 10.18895C5.534739999999999 10.18895 5.921100000000001 9.84215 6.78298 8.541649999999999Z" fill="white"/></svg>]====]},
    ["y"] = {w=7, h=14, advance=6.59784, source=[====[<svg width="7" height="14" viewBox="0 0 7 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M0.77954 4.25C0.95786 4.20665 1.07674 4.1922 1.2402 4.1922C1.84946 4.1922 2.1318 4.4234 2.4290000000000003 5.2036999999999995C2.8302199999999997 6.273 3.6029400000000003 9.3653 3.6029400000000003 9.914399999999999C3.6029400000000003 10.1456 3.49892 10.3768 3.2908799999999996 10.651349999999999C2.8747999999999996 11.186 2.53302 11.590599999999998 2.3547000000000002 11.77845C2.04264 12.09635 1.87918 12.21195 1.686 12.21195C1.58198 12.21195 1.49282 12.1686 1.3293599999999999 12.052999999999999C1.10646 11.8796 0.95786 11.80735 0.77954 11.80735C0.45262 11.80735 0.2 12.052999999999999 0.2 12.370899999999999C0.2 12.746599999999999 0.5120600000000001 13.006699999999999 0.95786 13.006699999999999C1.9089 13.006699999999999 3.8407 10.85365 5.46044 7.9780999999999995C6.47092 6.200749999999999 6.887 5.160349999999999 6.887 4.452299999999999C6.887 4.0188 6.515499999999999 3.6575499999999996 6.0697 3.6575499999999996C5.72792 3.6575499999999996 5.4901599999999995 3.8743 5.4901599999999995 4.1922C5.4901599999999995 4.4234 5.609039999999999 4.5679 5.9062399999999995 4.75575C6.18858 4.9147 6.2926 5.04475 6.2926 5.24705C6.2926 5.825049999999999 5.757639999999999 6.9376999999999995 4.47968 8.9896L4.18248 7.3134C3.95958 6.027349999999999 3.12742 3.6575499999999996 2.9045199999999998 3.6575499999999996H2.8450800000000003C2.81536 3.6719999999999997 2.7707800000000002 3.6719999999999997 2.71134 3.6719999999999997C2.59246 3.68645 2.04264 3.7731499999999993 1.25506 3.91765C1.18076 3.9320999999999993 0.98758 3.9754499999999995 0.77954 4.00435Z" fill="white"/></svg>]====]},
}

local wordmark_glyphs = {}
local WORDMARK_SEQUENCE = {"a","e","t","h","e","r","y","x"}
local WORDMARK_ADVANCE = 0

for name, glyph in pairs(WORDMARK_SOURCE) do
    local ok, texture = pcall(renderer.load_svg, glyph.source, glyph.w, glyph.h)
    if ok and texture ~= nil then
        wordmark_glyphs[name] = {
            texture=texture,
            w=glyph.w,
            h=glyph.h,
            advance=glyph.advance
        }
    end
end

for i = 1, #WORDMARK_SEQUENCE do
    local glyph = wordmark_glyphs[WORDMARK_SEQUENCE[i]]
    if glyph ~= nil then
        WORDMARK_ADVANCE = WORDMARK_ADVANCE + glyph.advance
    end
end

-- Literal behavior of source main[104]:
-- period=1.3, spread=0.5, sin wave across glyph indices.
local function wordmark_wave_colors(count, primary, secondary)
    local result = {}
    if count <= 0 then return result end

    local period = 1.3
    local spread = 0.5
    local phase_time = (globals.realtime() % period) / period

    for i = 1, count do
        local phase = (((i / count) * spread) - phase_time) % 1
        local t = math.max(0, math.sin(phase * math.pi))

        result[i] = {
            primary[1] + (secondary[1] - primary[1]) * t,
            primary[2] + (secondary[2] - primary[2]) * t,
            primary[3] + (secondary[3] - primary[3]) * t,
            primary[4] + (secondary[4] - primary[4]) * t
        }
    end

    return result
end

local function draw_aetheryx_wordmark(x, y, alpha)
    -- Match the supplied source reference: white logo with per-letter alpha shimmer.
    local primary = {255,255,255,255 * alpha}
    local secondary = {255,255,255,50 * alpha}
    local colors = wordmark_wave_colors(#WORDMARK_SEQUENCE, primary, secondary)

    local cursor = x
    for i = 1, #WORDMARK_SEQUENCE do
        local glyph = wordmark_glyphs[WORDMARK_SEQUENCE[i]]
        if glyph ~= nil then
            local c = colors[i]
            -- 14px glyph canvas is positioned so x-height/ascenders line up
            -- with source's recovered baseline (logo.render y ~= block_y + 17).
            renderer.texture(
                glyph.texture,
                cursor,
                y + 6,
                glyph.w,
                glyph.h,
                c[1], c[2], c[3], c[4]
            )
            cursor = cursor + glyph.advance
        end
    end
end

-- Shared by Center Indicators Star so the exact Watermark SVG wordmark is reused.
rawset(_G, '__aetheryx_svg_wordmark', {
    width = WORDMARK_ADVANCE,
    draw = draw_aetheryx_wordmark
})

local fps_value = 0
local fps_next_update = 0

local function current_time()
    if client.system_time ~= nil then
        local ok, h, m = pcall(client.system_time)
        if ok then
            return string.format("%02d:%02d", tonumber(h) or 0, tonumber(m) or 0)
        end
    end
    return "--:--"
end

local function username()
    return "bianca"
end

local function update_fps()
    local now = globals.realtime()
    if now < fps_next_update then return end
    local ft = tonumber(globals.frametime()) or 0.016
    if ft > 0 then fps_value = 1 / ft end
    fps_next_update = now + 0.3
end

local watermark_width_anim = new_anim(0)

local function watermark_items()
    update_fps()

    local result = {
        { icon=icons.person, text=username() },
        { icon=icons.frames, text=string.format("%ifps", fps_value) },
        { icon=icons.time, text=current_time() }
    }

    return result
end

-- Port of source factory main[90].
local function draw_watermark()
    if not element_enabled("Watermark") then return end

    local alpha = 1
    local ar, ag, ab = 255, 255, 255
    local items = watermark_items()

    -- source-style SVG wordmark: width comes from the individual glyph advances.
    local brand_w = WORDMARK_ADVANCE

    local items_w = 0
    for i = 1, #items do
        if i > 1 then items_w = items_w + 10 end
        items[i].text_w = text_width(items[i].text)
        local iw = items[i].icon and items[i].icon.w or 0
        items_w = items_w + iw + 5 + items[i].text_w
    end

    local item_width = math.floor(animate(watermark_width_anim, items_w))
    local have_items = #items > 0 and 1 or 0

    local total_w = item_width + brand_w + RADIUS * 2 * (1 + have_items) + 5 * have_items
    local sw = client.screen_size()
    local x = sw - total_w - 10
    local y = 10

    local brand_block_w = brand_w + RADIUS * 2
    glass_render_rect(x, y, brand_block_w, nil, ar, ag, ab, alpha)

    draw_aetheryx_wordmark(x + RADIUS, y, alpha)

    if have_items == 0 then return end

    x = x + brand_w + RADIUS * 2 + 5
    local info_block_w = item_width + RADIUS * 2
    glass_render_rect(x, y, info_block_w, nil, ar, ag, ab, alpha)

    local cursor = x + RADIUS

    for i = 1, #items do
        local item = items[i]
        if i > 1 then cursor = cursor + 10 end

        if item.icon ~= nil then
            local iy = y + (24 - item.icon.h) / 2
            render_icon(item.icon, cursor, iy, ar, ag, ab, 255*alpha)
            cursor = cursor + item.icon.w + 5
        end

        renderer.text(cursor, y + 5, 255,255,255,255*alpha, "", 0, item.text)
        cursor = cursor + item.text_w
    end
end

local function safe_native_bool(item)
    if item == nil then return false end
    local ok, value = pcall(ui.get, item)
    return ok and value == true
end

local function safe_item_bool(item)
    if item == nil then return false end
    if type(item) == "table" and type(item.get) == "function" then
        local ok, value = pcall(item.get, item)
        return ok and value == true
    end
    return safe_native_bool(item)
end

local features = menu_elements.antiaim.features
local manual = features.manual_yaw
local fs = features.freestanding

local binds = {
    {id="dt", name="Double tap", value="toggled", active=function() return reference.is_double_tap_active() end},
    {id="hs", name="Hide shots", value="toggled", active=function() return reference.is_on_shot_antiaim_active() end},
    {id="dmg", name="Damage override", value="active", active=function() return reference.is_override_minimum_damage() end},
    {id="baim", name="Force body aim", value="active", active=function() return safe_native_bool(reference.ragebot.aimbot.force_body_aim) end},
    {id="safe", name="Force safe point", value="active", active=function() return safe_native_bool(reference.ragebot.aimbot.force_safe_point) end},
    {id="peek", name="Quick peek", value="active", active=function() return reference.is_quick_peek_assist() end},
    {id="fs", name="Freestanding", value="active", active=function()
        return fs ~= nil and safe_item_bool(fs.checkbox) and safe_item_bool(fs.hotkey)
    end},
    {id="slow", name="Slow motion", value="active", active=function() return reference.is_slow_motion() end},
    {id="duck", name="Duck peek", value="active", active=function() return reference.is_duck_peek_assist() end},
    {id="manual_l", name="Manual left", value="active", active=function()
        return manual ~= nil and safe_item_bool(manual.checkbox) and aa_runtime_state.manual_direction == 'left'
    end},
    {id="manual_r", name="Manual right", value="active", active=function()
        return manual ~= nil and safe_item_bool(manual.checkbox) and aa_runtime_state.manual_direction == 'right'
    end},
    {id="manual_f", name="Manual forward", value="active", active=function()
        return manual ~= nil and safe_item_bool(manual.checkbox) and aa_runtime_state.manual_direction == 'forward'
    end}
}

local row_anims = {}
local hotkeys_width_anim = new_anim(HOTKEY_BASE_W)
local hotkeys_alpha_anim = new_anim(1)

for i = 1, #binds do
    row_anims[binds[i].id] = new_anim(0)
end

local function collect_hotkeys()
    local rows = {}
    local width = 0
    local alpha_sum = 0

    for i = 1, #binds do
        local bind = binds[i]
        local ok, active = pcall(bind.active)
        active = ok and active == true

        local a = animate(row_anims[bind.id], active and 1 or 0)
        if a > 0.001 then
            local name_w = text_width(bind.name)
            local value = bind.value or "active"
            local value_w = text_width(value)
            width = math.max(width, name_w + value_w + 34)
            alpha_sum = alpha_sum + a
            rows[#rows+1] = {
                bind=bind,
                alpha=a,
                name_w=name_w,
                value=value,
                value_w=value_w
            }
        end
    end

    return rows, width, alpha_sum
end

-- Port of source factory main[97].
local function draw_hotkeys()
    if not element_enabled("Keybinds") then
        animate(hotkeys_alpha_anim, 0)
        return
    end

    -- source keeps its Hotkeys header visible while the widget is enabled.
    local master_alpha = animate(hotkeys_alpha_anim, 1)
    if master_alpha <= 0.001 then return end

    local rows, target_width, alpha_sum = collect_hotkeys()
    local dynamic_width = math.max(target_width, HOTKEY_BASE_W)
    local width = math.floor(animate(hotkeys_width_anim, dynamic_width))

    local ar, ag, ab = accent()
    local drag_h = 30 + math.floor(10 + ROW_STEP * alpha_sum)

    local x, y = drag_system.update(
        "aetheryx_aetheryx_literal_hotkeys_v5",
        350, 300, width, drag_h
    )

    -- source draggable update returns its position; renderer offsets +4,+4.
    x = x + 4
    y = y + 4

    local brackets = icons.brackets
    local title = "Hotkeys"
    local title_w = text_width(title)
    local icon_w = brackets and brackets.w or 0
    local icon_h = brackets and brackets.h or 0
    local group_w = icon_w + 3 + title_w
    local group_x = x + (width - group_w) / 2

    glass_render_rect(x, y, width, nil, ar, ag, ab, master_alpha)

    if brackets ~= nil then
        render_icon(brackets, group_x, y + 6, ar, ag, ab, 255*master_alpha)
    end
    renderer.text(group_x + icon_w + 3, y + 6, 255,255,255,255*master_alpha, "", 0, title)

    if alpha_sum <= 0 then return end

    -- Exact factory main[97]: y+30, height 10 + 16 * sum(row alpha).
    glass_render_rect(
        x, y + 30, width, 10 + ROW_STEP * alpha_sum,
        ar, ag, ab, master_alpha
    )

    local row_index = 0

    for i = 1, #rows do
        local row = rows[i]
        local a = row.alpha * master_alpha
        local yy = y + 36 + ROW_STEP * row_index

        renderer.text(x + 12, yy, 255,255,255,255*a, "", 0, row.bind.name)
        renderer.text(x + width - row.value_w - 12, yy, 255,255,255,100*a, "", 0, row.value)

        row_index = row_index + row.alpha
    end
end

local function on_paint()
    if ref.glass_hud == nil or not ref.glass_hud:get() then
        fx_flush()
        return
    end

    draw_watermark()
    draw_hotkeys()

    -- source flushes the active Panorama instance every frame.
    fx_flush()
end

__aetheryx_runtime.set("paint", on_paint)
__aetheryx_runtime.set("shutdown", fx_release)
end


local console_filter do
local switch=menu_elements.other.miscellaneous.console_filter
local function set_int(cv,value)
if cv~=nil and type(cv.set_int)=='function' then pcall(cv.set_int,cv,value) end
end
local function set_string(cv,value)
if cv~=nil and type(cv.set_string)=='function' then pcall(cv.set_string,cv,value) end
end
local function apply()
if switch:get() then
set_int(cvar.developer,0)
set_int(cvar.con_filter_enable,1)
set_string(cvar.con_filter_text,'IrWL5106TZZKNFPz4P4Gl3pSN?J370f5hi373ZjPg%VOVh6lN')
client.exec('con_filter_enable 1')
else
set_int(cvar.con_filter_enable,0)
set_string(cvar.con_filter_text,'')
client.exec('con_filter_enable 0')
end
end
local function restore()
set_int(cvar.con_filter_enable,0)
set_string(cvar.con_filter_text,'')
client.exec('con_filter_enable 0')
end
switch:set_callback(function() apply() end,true)
__aetheryx_runtime.set('shutdown',restore)

__aetheryx_runtime.set('paint_ui', function()
if not ui.is_menu_open() then return end
local selector = menu_elements.category_selector
local categories = selector ~= nil and selector.categories or nil
local show = false
if categories ~= nil then
local ok_category, category = pcall(categories.get, categories)
show = ok_category and category == 'misc'
end
pcall(switch.set_visible, switch, show)
end)
end

local animated_zoom do
local ref = menu_elements.other.visual
local amount = 0
local function restore()
override.unset(
reference.misc.miscellaneous.override_zoom_fov
)
amount = 0
end
local function on_override_view(view)
if not ref.animated_zoom:get() then
restore()
return
end
override.set(
reference.misc.miscellaneous.override_zoom_fov,
0
)
local me = entity.get_local_player()
local scoped = me ~= nil
and me ~= 0
and entity.is_alive(me)
and entity.get_prop(me, 'm_bIsScoped') == 1
local target = scoped
and ref.animated_zoom_amount:get()
or 0
local factor = helper_motion.factor(ref.animated_zoom_speed:get())
amount = amount + (target - amount) * factor
if type(view.fov) == 'number' then
view.fov = view.fov - amount
end
end
__aetheryx_runtime.set(
'override_view',
on_override_view
)
__aetheryx_runtime.set('shutdown', restore)
end
local viewmodel_controller do
local ref = menu_elements.other.miscellaneous.viewmodel
local vars = {
fov = cvar.viewmodel_fov,
x = cvar.viewmodel_offset_x,
y = cvar.viewmodel_offset_y,
z = cvar.viewmodel_offset_z,
hand = cvar.cl_righthand
}
local defaults = nil
local last_values = nil
local function save_defaults()
if defaults ~= nil then
return
end
if vars.fov == nil or vars.x == nil or vars.y == nil or vars.z == nil then
return
end
defaults = {
fov = vars.fov:get_float(),
x = vars.x:get_float(),
y = vars.y:get_float(),
z = vars.z:get_float(),
hand = vars.hand ~= nil and vars.hand:get_int() or 1
}
end
local function restore()
if defaults == nil then
return
end
vars.fov:set_raw_float(defaults.fov)
vars.x:set_raw_float(defaults.x)
vars.y:set_raw_float(defaults.y)
vars.z:set_raw_float(defaults.z)
if vars.hand ~= nil then
vars.hand:set_raw_int(defaults.hand)
end
defaults = nil
last_values = nil
end
local function update()
if not ref.checkbox:get() then
restore()
return
end
save_defaults()
if defaults == nil then
return
end
local fov, x, y, z = ref.fov:get(), ref.offset_x:get(), ref.offset_y:get(), ref.offset_z:get()

-- "Opposite knife hand" must affect knives only.
-- Pistols / Scout / AWP / rifles / grenades keep the original cl_righthand value.
local hand = defaults.hand
if ref.options:get() then
local me = entity.get_local_player()
local weapon = me ~= nil and entity.get_player_weapon(me) or nil
if weapon ~= nil then
local classname = entity.get_classname(weapon) or ''
local info = csgo_weapons(weapon)
local is_knife = classname == 'CKnife'
or classname == 'CKnifeGG'
or (info ~= nil and info.type == 'knife')

if is_knife then
hand = defaults.hand == 0 and 1 or 0
end
end
end

local values = table.concat({fov, x, y, z, hand}, ':')
if values == last_values then return end
last_values = values
vars.fov:set_raw_float(fov / 10)
vars.x:set_raw_float(x / 10)
vars.y:set_raw_float(y / 10)
vars.z:set_raw_float(z / 10)
if vars.hand ~= nil then vars.hand:set_raw_int(hand) end
end
ref.reset:set_callback(function()
ref.fov:set(680)
ref.offset_x:set(0)
ref.offset_y:set(0)
ref.offset_z:set(0)
ref.options:set(false)
last_values = nil
update()
end)
__aetheryx_runtime.set('paint_ui', update)
__aetheryx_runtime.set('shutdown', restore)
end
local animation_breaker_controller do
local ref=menu_elements.other.miscellaneous.animation_breaker
local function entity_info(me)
-- Crash-safe: native animation overlay pointers can be transient/invalid on map load.
return nil
end
local function overlay(info,index)
return nil
end
local function set_weight(layer,value) if layer~=nil then pcall(function() layer.weight=value end) end end
local function pose(me,index,value) pcall(entity.set_prop,me,'m_flPoseParameter',value,index) end
local function restore() override.unset(reference.antiaim.other.leg_movement) end
local function on_pre_render()
if not ref.checkbox:get() then restore(); return end
local me=entity.get_local_player(); if me==nil or me==0 or not entity.is_alive(me) then restore(); return end
local info=entity_info(me); local layer12=overlay(info,12); local vx,vy=entity.get_prop(me,'m_vecVelocity'); local speed=math.sqrt((vx or 0)^2+(vy or 0)^2); local flags=entity.get_prop(me,'m_fFlags') or 0; local air=bit.band(flags,1)~=1
if ref.triggers:get('Ground') and not air then
local mode=ref.ground_mode:get(); local amount=ref.ground_amount:get()/10
if mode=='Static' then pose(me,0,1); override.set(reference.antiaim.other.leg_movement,'Always slide')
elseif mode=='Jitter' then pose(me,0,(globals.tickcount()%4>1) and amount or 0); override.set(reference.antiaim.other.leg_movement,'Always slide')
elseif mode=='Modern' then pose(me,0,client.random_float(0.1,1)); override.set(reference.antiaim.other.leg_movement,client.random_int(1,2)==1 and 'Off' or 'Always slide'); if speed>=3 then set_weight(layer12,1) end
elseif mode=='Broken' then override.set(reference.antiaim.other.leg_movement,'Off'); pose(me,3,client.random_float(0.1,1)); pose(me,7,client.random_float(0.1,1)); pose(me,6,client.random_float(0.1,1)) end
else override.unset(reference.antiaim.other.leg_movement) end
if ref.triggers:get('Air') and air then local mode=ref.air_mode:get(); local amount=ref.air_amount:get()/10; if mode=='Static' then pose(me,6,amount) elseif mode=='Jitter' then pose(me,6,client.random_float(0.1,1)) elseif mode=='Broken' then pose(me,3,client.random_float(0.1,1)); pose(me,7,client.random_float(0.1,1)); pose(me,6,client.random_float(0.1,1)) end end
if ref.triggers:get('Tweaks') then
if ref.tweaks:get('Lizginka') then set_weight(overlay(info,7),client.random_float(0.9,1)); pose(me,0,(globals.tickcount()%3>1) and 0.9 or 0) end
if ref.tweaks:get('Body Lean') then set_weight(layer12,ref.tweaks_amount:get()/10) end
if ref.tweaks:get('Earthshake') then set_weight(layer12,client.random_float(0.1,1)) end
end
end
local function on_setup_command(cmd)
if not ref.checkbox:get() or not ref.triggers:get('Tweaks') or not ref.tweaks:get('Movement On Peek Assist') or not reference.is_quick_peek_assist() then return end
local me=entity.get_local_player(); if me==nil or entity.get_prop(me,'m_MoveType')~=2 then return end
cmd.in_forward=0; cmd.in_back=0; cmd.in_moveleft=0; cmd.in_moveright=0
end
__aetheryx_runtime.set('pre_render',on_pre_render)
__aetheryx_runtime.set('setup_command',on_setup_command)
__aetheryx_runtime.set('shutdown',restore)
end
local force_shot_controller do
local ref = menu_elements.other.force_shot
local hitchance_ref = reference.ragebot.aimbot.minimum_hit_chance
local weapon_type_ref = reference.ragebot.weapon_type
local hc_forced = false
local forced_profile = nil
local saved_hitchance = { }
local profile_cache = { }

local function restore_selector(value)
if value ~= nil then pcall(ui.set, weapon_type_ref, value) end
end

local function select_native_profile(candidates)
if candidates == nil or #candidates == 0 then return nil end
local cache_key = table.concat(candidates, '|')
if profile_cache[cache_key] ~= nil then return profile_cache[cache_key] or nil end
local previous = ui.get(weapon_type_ref)
local found = nil
for i = 1, #candidates do
local candidate = candidates[i]
local ok = pcall(ui.set, weapon_type_ref, candidate)
if ok then
local current = ui.get(weapon_type_ref)
if current == candidate then
found = candidate
break
end
end
end
restore_selector(previous)
profile_cache[cache_key] = found or false
return found
end

local function weapon_profile_candidates(weapon)
if weapon == nil then return { 'Global' } end
local idx = bit.band(tonumber(entity.get_prop(weapon, 'm_iItemDefinitionIndex')) or 0, 0xFFFF)
if idx == 31 then return { 'Taser', 'Zeus' } end
if idx == 1 then return { 'Desert Eagle', 'Deagle' } end
if idx == 64 then return { 'R8 Revolver', 'Revolver' } end
if idx == 40 then return { 'SSG 08', 'Scout', 'SSG-08' } end
if idx == 9 then return { 'AWP' } end
if idx == 11 or idx == 38 then return { 'G3SG1 / SCAR-20', 'Auto Snipers', 'AutoSnipers' } end

local ok, info = pcall(csgo_weapons, weapon)
if ok and info ~= nil then
local t = info.type
if t == 'pistol' then return { 'Pistols' } end
if t == 'rifle' then return { 'Rifles' } end
if t == 'smg' then return { 'SMGs', 'SMG' } end
if t == 'shotgun' then return { 'Shotguns', 'Shotgun' } end
if t == 'machinegun' then return { 'Machine gun', 'Machine Gun', 'Machine Guns' } end
end
return { 'Global' }
end

local function restore_profile(profile)
if profile == nil then return end
local value = saved_hitchance[profile]
if value == nil then return end
local previous = ui.get(weapon_type_ref)
local ok = pcall(ui.set, weapon_type_ref, profile)
if ok and ui.get(weapon_type_ref) == profile then
pcall(ui.set, hitchance_ref, value)
end
restore_selector(previous)
saved_hitchance[profile] = nil
end

local function release_hitchance()
if forced_profile ~= nil then restore_profile(forced_profile) end
forced_profile = nil
hc_forced = false
force_shot_indicator_active = false
end

local function force_profile_hitchance(profile, value)
if profile == nil then return false end
if forced_profile ~= nil and forced_profile ~= profile then
restore_profile(forced_profile)
forced_profile = nil
end
local previous = ui.get(weapon_type_ref)
local ok = pcall(ui.set, weapon_type_ref, profile)
if not ok or ui.get(weapon_type_ref) ~= profile then
restore_selector(previous)
return false
end
if saved_hitchance[profile] == nil then
saved_hitchance[profile] = ui.get(hitchance_ref)
end
pcall(ui.set, hitchance_ref, value)
restore_selector(previous)
forced_profile = profile
hc_forced = true
return true
end

local function is_on_ground(player)
if player == nil then return false end
local flags = tonumber(entity.get_prop(player, 'm_fFlags')) or 0
return bit.band(flags, bit.lshift(1, 0)) ~= 0
end

local function force_shot_triggered(local_player, weapon)
if local_player == nil or weapon == nil then return false end

-- Neverlose source uses weapon:get_inaccuracy() == 0. GameSense does not
-- expose that method directly, so the port uses the corresponding accuracy
-- penalty netvar and treats a practically-zero value as zero inaccuracy.
local inaccuracy = tonumber(entity.get_prop(weapon, 'm_fAccuracyPenalty'))
if type(inaccuracy) ~= 'number' then return false end
local zero_inaccuracy = math.abs(inaccuracy) <= 0.000001
local definition_index = bit.band(tonumber(entity.get_prop(weapon, 'm_iItemDefinitionIndex')) or 0, 0xFFFF)

if definition_index == 40 then
if ref.on_ground:get() == true then
return zero_inaccuracy
end
return zero_inaccuracy or not is_on_ground(local_player)
end

return zero_inaccuracy
end

local function update_force_shot()
if ref == nil or not ref.checkbox:get() or not ref.hotkey:get() then
release_hitchance()
return
end
local local_player = entity.get_local_player()
if local_player == nil or not entity.is_alive(local_player) then
release_hitchance()
return
end
local weapon = entity.get_player_weapon(local_player)
if weapon == nil then
release_hitchance()
return
end
if not force_shot_triggered(local_player, weapon) then
release_hitchance()
return
end

local profile = select_native_profile(weapon_profile_candidates(weapon))
if profile == nil then
release_hitchance()
return
end
local hitchance = ref.minimum_hitchance:get()
if force_profile_hitchance(profile, hitchance) then
force_shot_indicator_active = true
else
release_hitchance()
end
end

__aetheryx_runtime.set('setup_command', update_force_shot)
__aetheryx_runtime.set('shutdown', release_hitchance)
end

local native_skeet_hotkey_indicators do
local function on_paint()
if force_shot_indicator_active then
renderer.indicator(255, 255, 255, 255, 'SHOT')
end
end
__aetheryx_runtime.set('paint', on_paint)
end

local config = { } do
local ref = menu_elements.home.config_local
local DB_NAME = '##AETHERYX_CONFIGS_V2'
local STORAGE_KEY = 'aetheryx_configs_v2'
local db_data = localdb[STORAGE_KEY] or database.read(DB_NAME) or { }
if type(db_data) ~= 'table' then
db_data = { }
end
local config_data = { }
local config_list = { }
local config_defaults = { }
local function aa_val(...)
return { ... }
end
local function aa_copy(dst, src)
for k, v in pairs(src) do
dst[k] = v
end
end
local function aa_state_keys(state, values)
local out = { }
for key, value in pairs(values) do
out[state .. ':' .. key] = value
end
return out
end
local ideal_state_profile = {
['Shared'] = {
yaw_base = aa_val('At targets'),
yaw_type = aa_val('Left / Right'),
yaw_side = aa_val('Left'),
yaw_left_offset = aa_val(-27),
yaw_right_offset = aa_val(47),
yaw_left_random = aa_val(0),
yaw_right_random = aa_val(0),
yaw_180_offset = aa_val(0),
yaw_random = aa_val(0),
yaw_jitter = aa_val('Off'),
jitter_offset = aa_val(0),
jitter_random = aa_val(0),
body_yaw = aa_val('Static'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(1),
delay_to = aa_val(0),
anti_bruteforce_enabled = aa_val(true),
defensive_force_defensive = aa_val(false),
defensive_enabled = aa_val(false),
defensive_type = aa_val('Default'),
defensive_pitch = aa_val('Off'),
defensive_yaw = aa_val('Off')
},
['Standing'] = {
enabled = aa_val(true),
yaw_base = aa_val('At targets'),
yaw_type = aa_val('Left / Right'),
yaw_side = aa_val('Left'),
yaw_left_offset = aa_val(-27),
yaw_right_offset = aa_val(47),
yaw_left_random = aa_val(0),
yaw_right_random = aa_val(0),
yaw_jitter = aa_val('Off'),
jitter_offset = aa_val(0),
body_yaw = aa_val('Static'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(1),
delay_to = aa_val(0),
anti_bruteforce_enabled = aa_val(true),
defensive_enabled = aa_val(true),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false),
defensive_pitch = aa_val('Custom'),
defensive_pitch_offset = aa_val(-45),
defensive_yaw = aa_val('Static'),
defensive_yaw_offset = aa_val(90)
},
['Moving'] = {
enabled = aa_val(true),
yaw_base = aa_val('At targets'),
yaw_type = aa_val('Left / Right'),
yaw_side = aa_val('Left'),
yaw_left_offset = aa_val(-29),
yaw_right_offset = aa_val(49),
yaw_left_random = aa_val(3),
yaw_right_random = aa_val(3),
yaw_jitter = aa_val('Center'),
jitter_offset = aa_val(18),
jitter_random = aa_val(5),
body_yaw = aa_val('Jitter'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(2),
delay_to = aa_val(3),
anti_bruteforce_enabled = aa_val(true),
defensive_enabled = aa_val(false),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false)
},
['Slow Walk'] = {
enabled = aa_val(true),
yaw_base = aa_val('At targets'),
yaw_type = aa_val('Left / Right'),
yaw_side = aa_val('Left'),
yaw_left_offset = aa_val(-36),
yaw_right_offset = aa_val(56),
yaw_left_random = aa_val(0),
yaw_right_random = aa_val(0),
yaw_jitter = aa_val('Off'),
jitter_offset = aa_val(0),
body_yaw = aa_val('Static'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(1),
delay_to = aa_val(0),
anti_bruteforce_enabled = aa_val(true),
defensive_enabled = aa_val(false),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false)
},
['Crouching'] = {
enabled = aa_val(true),
yaw_base = aa_val('At targets'),
yaw_type = aa_val('Left / Right'),
yaw_side = aa_val('Left'),
yaw_left_offset = aa_val(-26),
yaw_right_offset = aa_val(46),
yaw_left_random = aa_val(0),
yaw_right_random = aa_val(0),
yaw_jitter = aa_val('Off'),
jitter_offset = aa_val(0),
body_yaw = aa_val('Static'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(1),
delay_to = aa_val(0),
anti_bruteforce_enabled = aa_val(true),
defensive_enabled = aa_val(true),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false),
defensive_pitch = aa_val('Custom'),
defensive_pitch_offset = aa_val(-35),
defensive_yaw = aa_val('Static'),
defensive_yaw_offset = aa_val(90)
},
['Crouching & Move'] = {
enabled = aa_val(true),
yaw_base = aa_val('At targets'),
yaw_type = aa_val('Left / Right'),
yaw_side = aa_val('Left'),
yaw_left_offset = aa_val(-27),
yaw_right_offset = aa_val(47),
yaw_left_random = aa_val(2),
yaw_right_random = aa_val(2),
yaw_jitter = aa_val('Center'),
jitter_offset = aa_val(12),
jitter_random = aa_val(4),
body_yaw = aa_val('Jitter'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(2),
delay_to = aa_val(2),
anti_bruteforce_enabled = aa_val(true),
defensive_enabled = aa_val(true),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false),
defensive_pitch = aa_val('Custom'),
defensive_pitch_offset = aa_val(-40),
defensive_yaw = aa_val('Static'),
defensive_yaw_offset = aa_val(90)
},
['Air'] = {
enabled = aa_val(true),
yaw_base = aa_val('At targets'),
yaw_type = aa_val('Left / Right'),
yaw_side = aa_val('Left'),
yaw_left_offset = aa_val(-24),
yaw_right_offset = aa_val(44),
yaw_left_random = aa_val(5),
yaw_right_random = aa_val(5),
yaw_jitter = aa_val('Center'),
jitter_offset = aa_val(24),
jitter_random = aa_val(8),
body_yaw = aa_val('Jitter'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(1),
delay_to = aa_val(2),
anti_bruteforce_enabled = aa_val(true),
defensive_enabled = aa_val(false),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false)
},
['Air & Crouched'] = {
enabled = aa_val(true),
yaw_base = aa_val('At targets'),
yaw_type = aa_val('Left / Right'),
yaw_side = aa_val('Left'),
yaw_left_offset = aa_val(-23),
yaw_right_offset = aa_val(43),
yaw_left_random = aa_val(4),
yaw_right_random = aa_val(4),
yaw_jitter = aa_val('Center'),
jitter_offset = aa_val(20),
jitter_random = aa_val(6),
body_yaw = aa_val('Jitter'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(1),
delay_to = aa_val(2),
anti_bruteforce_enabled = aa_val(true),
defensive_enabled = aa_val(false),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false)
},
['Freestanding'] = {
enabled = aa_val(true),
yaw_base = aa_val('At targets'),
yaw_type = aa_val('180'),
yaw_180_offset = aa_val(0),
yaw_random = aa_val(0),
yaw_jitter = aa_val('Off'),
jitter_offset = aa_val(0),
body_yaw = aa_val('Static'),
body_yaw_offset = aa_val(58),
freestanding_body_yaw = aa_val(true),
delay_from = aa_val(1),
delay_to = aa_val(0),
anti_bruteforce_enabled = aa_val(true),
defensive_enabled = aa_val(false),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false)
},
['Legit AA'] = {
enabled = aa_val(true),
bomb_e_fix = aa_val(true),
yaw_base = aa_val('Local view'),
yaw_type = aa_val('180'),
yaw_180_offset = aa_val(180),
yaw_random = aa_val(0),
yaw_jitter = aa_val('Off'),
jitter_offset = aa_val(0),
body_yaw = aa_val('Opposite'),
body_yaw_offset = aa_val(0),
freestanding_body_yaw = aa_val(false),
delay_from = aa_val(1),
delay_to = aa_val(0),
anti_bruteforce_enabled = aa_val(false),
defensive_enabled = aa_val(false),
defensive_type = aa_val('Default'),
defensive_force_defensive = aa_val(false)
}
}
local function build_ideal_builder(profile_map)
local builder = { }
for state, values in pairs(profile_map) do
aa_copy(builder, aa_state_keys(state, values))
end
return builder
end
local ideal_features = {
['avoid_backstab.enabled'] = aa_val(true),
['avoid_backstab.distance'] = aa_val(240),
['safe_head.checkbox'] = aa_val(true),
['safe_head.select'] = aa_val({ 'Knife', 'Taser' }),
['safe_head.conditions'] = aa_val({ 'Standing', 'Crouch', 'Air crouch', 'Air crouch knife', 'Air crouch taser' }),
['safe_head.options'] = aa_val({}),
['manual_yaw.checkbox'] = aa_val(true),
['manual_yaw.forward'] = aa_val('Toggle', 0),
['manual_yaw.left'] = aa_val('Toggle', 0),
['manual_yaw.right'] = aa_val('Toggle', 0),
['manual_yaw.arrows_style'] = aa_val('Invictus'),
['manual_yaw.arrows_dynamic'] = aa_val(true),
['manual_yaw.freestanding_body'] = aa_val(false),
['freestanding.checkbox'] = aa_val(true),
['freestanding.disablers'] = aa_val({ 'Air' })
}
local function make_aa_preset(name, builder_profile, feature_overrides, author)
local features = { }
aa_copy(features, ideal_features)
if feature_overrides ~= nil then
aa_copy(features, feature_overrides)
end
return {
name = name,
author = author or 'Ideal Yaw',
date = '24.07.2026',
aa_only = true,
data = {
Builder = build_ideal_builder(builder_profile),
Features = features
}
}
end
local default_profile = { }
for state, values in pairs(ideal_state_profile) do
local copy = { }
aa_copy(copy, values)
if copy.yaw_left_offset ~= nil then
copy.yaw_left_offset = aa_val((copy.yaw_left_offset[1] or -27) - 4)
end
if copy.yaw_right_offset ~= nil then
copy.yaw_right_offset = aa_val((copy.yaw_right_offset[1] or 47) + 4)
end
if state == 'Moving' or state == 'Air' or state == 'Air & Crouched' or state == 'Crouching & Move' then
copy.yaw_jitter = aa_val('Skitter')
copy.jitter_offset = aa_val(28)
copy.jitter_random = aa_val(10)
copy.body_yaw = aa_val('Jitter')
copy.delay_from = aa_val(1)
copy.delay_to = aa_val(2)
end
default_profile[state] = copy
end
local default_preset = make_aa_preset(
'Default',
default_profile,
{
['freestanding.disablers'] = aa_val({})
},
script.user
)
config_defaults[1] = default_preset
config_defaults[2] = nil
config_defaults[3] = nil
config_defaults[4] = nil
local function lock_clr()
return utils.to_hex(75, 75, 75, 255)
end
local function def_clr()
return utils.to_hex(200, 200, 200, 255)
end
local function get_current_date()
local unix_time = client.unix_time()
local days_since_epoch = math.floor(unix_time / 86400)
local year = 1970
local month = 1
local day = 1
local days_in_month = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
local function is_leap_year(y)
return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end
local remaining_days = days_since_epoch
while remaining_days >= 365 do
local days_in_year = is_leap_year(year) and 366 or 365
if remaining_days >= days_in_year then
remaining_days = remaining_days - days_in_year
year = year + 1
else
break
end
end
while remaining_days > 0 do
local days_this_month = days_in_month[month]
if month == 2 and is_leap_year(year) then
days_this_month = 29
end
if remaining_days >= days_this_month then
remaining_days = remaining_days - days_this_month
month = month + 1
if month > 12 then
month = 1
year = year + 1
end
else
day = remaining_days + 1
break
end
end
return string.format("%02d.%02d.%04d", day, month, year)
end
local function get_current_author()
return script.user
end
local function update_config_info_ui(config_info)
local author_label = string.format(
'\a%s%s \a%s~  \a%sAuthor \a%s| \a%s%s',
reference.get_color(true),
'',
lock_clr(),
def_clr(),
lock_clr(),
reference.get_color(true),
config_info.author or 'Unknown'
)
local date_label = string.format(
'\a%s%s \a%s~  \a%sCreated at \a%s| \a%s%s',
reference.get_color(true),
'',
lock_clr(),
def_clr(),
lock_clr(),
reference.get_color(true),
config_info.date or 'Unknown'
)
ref.author:set(author_label)
ref.data:set(date_label)
end
local function clear_config_info_ui()
local empty_author = string.format(
'\a%s%s \a%s~  \a%sAuthor \a%s| \a%s%s',
reference.get_color(true),
'',
lock_clr(),
def_clr(),
lock_clr(),
reference.get_color(true),
'None'
)
local empty_date = string.format(
'\a%s%s \a%s~  \a%sCreated at \a%s| \a%s%s',
reference.get_color(true),
'',
lock_clr(),
def_clr(),
lock_clr(),
reference.get_color(true),
'None'
)
ref.author:set(empty_author)
ref.data:set(empty_date)
end
for i = 1, #db_data do
local entry = db_data[i]
if type(entry) == 'table'
and type(entry.name) == 'string'
and entry.name ~= ''
and type(entry.data) == 'table' then
config_data[#config_data + 1] = {
name = entry.name,
data = entry.data,
author = entry.author or 'Unknown',
date = entry.date or 'Unknown'
}
end
end
for i = #config_defaults, 1, -1 do
local list = config_defaults[i]
if list.data == nil then
goto continue
end
if type(list.data) == 'string' then
local ok, result = config_system.decode(list.data)
if not ok then
list.data = config_system.export()
else
list.data = result
end
end
::continue::
end
local function create_config(name, data, is_default, author, date)
local list = { }
list.name = name
list.data = data
list.default = is_default
list.author = author or "Unknown"
list.date = date or "Unknown"
return list
end
local function find_config(name)
local normalized = name:lower()
for i = 1, #config_list do
local data = config_list[i]
if data.name:lower() == normalized then
return data, i
end
end
return nil, -1
end
local function save_config_data()
localdb[STORAGE_KEY] = config_data
database.write(DB_NAME, config_data)
end
local function select_config(name)
local list, index = find_config(name)
if list == nil then
clear_config_info_ui()
return
end
ref.list:set(index - 1)
ref.input:set(list.name)
update_config_info_ui(list)
end
local function update_config_list()
for i = 1, #config_list do
config_list[i] = nil
end
for i = 1, #config_defaults do
local list = config_defaults[i]
local cell = create_config(
list.name,
list.data,
true,
list.author,
list.date
)
table.insert(config_list, cell)
end
for i = 1, #config_data do
local list = config_data[i]
local cell = create_config(
list.name,
list.data,
false,
list.author,
list.date
)
cell.data_index = i
table.insert(config_list, cell)
end
end
local function get_render_list()
local result = { }
for i = 1, #config_list do
local list = config_list[i]
local name = list.name
if list.default then
name = string.format('%s*', name)
end
table.insert(result, name)
end
return result
end
local function load_config(name, categories)
local list, idx = find_config(name)
if list == nil or idx == -1 then
logging.error(string.format(
'config %s was not found', name
))
return
end
local ok, result = config_system.import(
list.data, categories
)
if not ok then
logging.error(string.format(
'failed to import %s config: %s', name, result
))
return
end
logging.success(string.format(
'loaded %s config', name
))
aetheryx_evalate_sound(0.3)
select_config(list.name)
end
local function save_config(name)
local cfg_data = config_system.export()
local current_author = get_current_author()
local current_date = get_current_date()
local list, idx = find_config(name)
if list == nil or idx == -1 then
table.insert(config_data, {
name = name,
data = cfg_data,
author = current_author,
date = current_date
})
save_config_data()
update_config_list()
ref.list:update(get_render_list())
select_config(name)
logging.success(string.format(
'created %s config', name
))
aetheryx_evalate_sound(0.3)
return
end
if list.default then
logging.error(string.format(
'you can\'t edit %s config', name
))
return
end
list.data = cfg_data
list.date = current_date
if list.data_index ~= nil then
local data_cell = config_data[list.data_index]
if data_cell ~= nil then
data_cell.data = cfg_data
data_cell.date = current_date
end
end
save_config_data()
update_config_list()
ref.list:update(get_render_list())
select_config(name)
logging.success(string.format(
'saved %s config', name
))
aetheryx_evalate_sound(0.3)
end
local function delete_config(name)
local list, idx = find_config(name)
if list == nil or idx == -1 then
logging.error(string.format(
'config %s was not found', name
))
return
end
if list.default then
logging.error(string.format(
'you can\'t delete %s config', name
))
return
end
local data_index = list.data_index
if data_index == nil then
return
end
table.remove(config_data, data_index)
save_config_data()
update_config_list()
ref.list:update(get_render_list())
local next_index = math.min(idx, #config_list)
local next_config = config_list[next_index]
logging.success(string.format(
'deleted %s config', name
))
if next_config ~= nil then
select_config(next_config.name)
else
ref.input:set('')
clear_config_info_ui()
end
end
local callbacks do
local function on_list(item)
local index = item:get()
if index == nil then
return
end
local list = config_list[index + 1]
if list == nil then
clear_config_info_ui()
return
end
ref.input:set(list.name)
update_config_info_ui(list)
end
local function on_load()
local name = utils.trim(
ref.input:get()
)
if name == '' then
return
end
load_config(name)
end
local function on_save()
local name = utils.trim(
ref.input:get()
)
if name == '' then
return
end
save_config(name)
end
local function on_delete()
local name = utils.trim(
ref.input:get()
)
if name == '' then
return
end
delete_config(name)
end
local function on_export()
local ok, result = config_system.encode(
config_system.export()
)
if not ok then
logging.error('failed to export config')
return
end
clipboard.set(result)
logging.success(
'exported config to clipboard'
)
end
local function on_import()
local str = clipboard.get()
if str == nil or utils.trim(str) == '' then
logging.error('clipboard is empty')
return
end
local ok, result = config_system.decode(utils.trim(str))
if not ok then
logging.error('clipboard does not contain a valid Aetheryx config')
return
end
local imported, import_error = config_system.import(result)
if not imported then
logging.error(string.format(
'failed to import config: %s', import_error or 'unknown error'
))
return
end
logging.success(
'imported config from clipboard'
)
end
ref.list:set_callback(on_list)
ref.load:set_callback(on_load)
ref.save:set_callback(on_save)
ref.delete:set_callback(on_delete)
ref.export:set_callback(on_export)
ref.import:set_callback(on_import)
end
update_config_list()
ref.list:update(get_render_list())
if #config_list > 0 then
select_config(config_list[1].name)
else
clear_config_info_ui()
end
end
local rage do
local function on_shutdown()
ragebot.unset(reference.ragebot.aimbot.enabled[1])
ragebot.unset(reference.ragebot.aimbot.double_tap[1])
end
local function on_setup_command(cmd)
ragebot.unset(reference.ragebot.aimbot.enabled[1])
ragebot.unset(reference.ragebot.aimbot.double_tap[1])
end
utils.event_callback('shutdown', on_shutdown)
utils.event_callback('setup_command', on_setup_command)
end
local misc_aspect_ratio do
local ref = menu_elements.other.miscellaneous.aspect_ratio
local aspect_ratio = cvar.r_aspectratio
local original = aspect_ratio ~= nil and aspect_ratio:get_float() or 0
local function restore()
if aspect_ratio ~= nil then aspect_ratio:set_raw_float(original) end
end
local preset_values = {
[0] = 0,
[1] = 1.33,
[2] = 1.25,
[3] = 1.50,
[4] = 1.60,
[5] = 1.78,
[6] = 2.33
}
local function update()
if aspect_ratio == nil then return end
if ref.checkbox:get() then
aspect_ratio:set_raw_float(preset_values[ref.value:get()] or 0)
else
restore()
end
end
ref.checkbox:set_callback(update, true)
ref.value:set_callback(update, true)
utils.event_callback('shutdown', restore)
utils.event_callback('pre_config_save', function()
restore()
__aetheryx_runtime.delay(0, update)
end)
end
local bullet_tracer_controller do
local ref = menu_elements.other.miscellaneous.bullet_tracer
local queue = { }

local function on_bullet_impact(e)
if not ref.checkbox:get() then return end
if client.userid_to_entindex(e.userid) ~= entity.get_local_player() then return end
local lx, ly, lz = client.eye_position()
queue[globals.tickcount()] = { lx, ly, lz, e.x, e.y, e.z, globals.curtime() + 4 }
end

local function on_paint()
if not ref.checkbox:get() then return end
local r, g, b, a = ref.color:get()
for tick, data in pairs(queue) do
if globals.curtime() <= data[7] then
local x1, y1 = renderer.world_to_screen(data[1], data[2], data[3])
local x2, y2 = renderer.world_to_screen(data[4], data[5], data[6])
if x1 ~= nil and x2 ~= nil and y1 ~= nil and y2 ~= nil then
renderer.line(x1, y1, x2, y2, r, g, b, a)
end
else
queue[tick] = nil
end
end
end

local function reset_queue()
queue = { }
end

local function on_local_death(e)
local me = entity.get_local_player()
if me ~= nil and client.userid_to_entindex(e.userid) == me then
reset_queue()
end
end

__aetheryx_runtime.set('bullet_impact', on_bullet_impact)
__aetheryx_runtime.set('paint', on_paint)
__aetheryx_runtime.set('round_prestart', reset_queue)
__aetheryx_runtime.set('round_end', reset_queue)
__aetheryx_runtime.set('player_death', on_local_death)
end

local plus_hitmarker_controller do
local ref = menu_elements.other.miscellaneous.plus_hitmarker
local queue = { }

local function on_aim_fire(c)
if not ref.checkbox:get() then return end
queue[globals.tickcount()] = { c.x, c.y, c.z, globals.curtime() + 4 }
end

local function on_paint()
if not ref.checkbox:get() then return end
for tick, data in pairs(queue) do
if globals.curtime() <= data[4] then
local x1, y1 = renderer.world_to_screen(data[1], data[2], data[3])
if x1 ~= nil and y1 ~= nil then
renderer.line(x1 - 6, y1, x1 + 6, y1, 0, 255, 255, 255)
renderer.line(x1, y1 - 6, x1, y1 + 6, 0, 255, 0, 255)
end
else
queue[tick] = nil
end
end
end

local function reset_queue()
queue = { }
end

local function on_local_death(e)
local me = entity.get_local_player()
if me ~= nil and client.userid_to_entindex(e.userid) == me then
reset_queue()
end
end

__aetheryx_runtime.set('aim_fire', on_aim_fire)
__aetheryx_runtime.set('paint', on_paint)
__aetheryx_runtime.set('round_prestart', reset_queue)
__aetheryx_runtime.set('round_end', reset_queue)
__aetheryx_runtime.set('player_death', on_local_death)
end

local misc do
local game_enhancer = { } do
local ref = menu_elements.other.miscellaneous.game_enhancer
local changed = false
local tree = { } do
local function wrap(convar, value)
local item = { }
item.convar = convar
item.old_value = nil
item.new_value = value
return item
end
tree['Fix chams color'] = {
wrap(cvar.mat_autoexposure_max_multiplier, 0.2)
}
tree['Disable dynamic lighting'] = {
wrap(cvar.r_dynamiclighting, 0)
}
tree['Disable dynamic shadows'] = {
wrap(cvar.r_dynamic, 0)
}
tree['Disable first-person tracers'] = {
wrap(cvar.r_drawtracers_firstperson, 0)
}
tree['Disable ragdolls'] = {
wrap(cvar.cl_disable_ragdolls, 1)
}
tree['Disable eye gloss'] = {
wrap(cvar.r_eyegloss, 0)
}
tree['Disable eye movement'] = {
wrap(cvar.r_eyemove, 0)
}
tree['Disable muzzle flash light'] = {
wrap(cvar.muzzleflash_light, 0)
}
tree['Enable low CPU audio'] = {
wrap(cvar.dsp_slow_cpu, 1)
}
tree['Disable bloom'] = {
wrap(cvar.mat_disable_bloom, 1)
}
tree['Disable particles'] = {
wrap(cvar.r_drawparticles, 0)
}
tree['Reduce breakable objects'] = {
wrap(cvar.func_break_max_pieces, 0)
}
end
local function restore_convars()
if not changed then
return
end
for _, v in pairs(tree) do
for i = 1, #v do
local item = v[i]
local convar = item.convar
if item.old_value == nil then
goto continue
end
convar:set_int(item.old_value)
item.old_value = nil
::continue::
end
end
changed = false
end
local function update_convars()
if changed then
return
end
local values = ref.list:get()
for i = 1, #values do
local value = values[i]
local items = tree[value]
for j = 1, #items do
local item = items[j]
local convar = item.convar
if convar == nil or item.old_value ~= nil then
goto continue
end
item.old_value = convar:get_int()
convar:set_int(item.new_value)
::continue::
end
end
changed = true
end
local function on_shutdown()
restore_convars()
end
local function on_net_update_end()
if not ref.checkbox:get() then
return restore_convars()
end
update_convars()
end
local callbacks do
local function on_list(item)
restore_convars()
update_convars()
end
local function update_event_callbacks(item)
local value = item:get()
if value then
ref.list:set_callback(on_list, true)
else
ref.list:unset_callback(on_list)
end
if not value then
restore_convars()
end
utils.event_callback(
'shutdown',
on_shutdown,
value
)
utils.event_callback(
'net_update_end',
on_net_update_end,
value
)
end
ref.checkbox:set_callback(
update_event_callbacks, true
)
end
end
end
local antiaim do
local buffer = { } do
local ref = reference.antiaim.angles
local applied_native_values = { }
local native_menu_was_open = false
local last_native_mode_signature = nil
local function values_equal_args(previous, count, ...)
if previous == nil or previous.n ~= count then return false end
for i = 1, count do
if previous[i] ~= select(i, ...) then return false end
end
return true
end
local function override_value(item, ...)
local count = select('#', ...)
local first = select(1, ...)
if count == 0 or first == nil then
if applied_native_values[item] ~= nil then
override.unset(item)
applied_native_values[item] = nil
end
return
end
local previous = applied_native_values[item]
if values_equal_args(previous, count, ...) then return end
override.set(item, ...)
local stored = previous or { n = 0 }
for i = 1, stored.n or 0 do stored[i] = nil end
stored.n = count
for i = 1, count do stored[i] = select(i, ...) end
applied_native_values[item] = stored
end
local function native_mode_signature(buffer)
return table.concat({
tostring(buffer.enabled), tostring(buffer.pitch), tostring(buffer.yaw_base),
tostring(buffer.yaw), tostring(buffer.yaw_jitter), tostring(buffer.body_yaw),
tostring(buffer.freestanding_body_yaw), tostring(buffer.edge_yaw),
tostring(buffer.freestanding), tostring(buffer.roll)
}, '|')
end
local function hide_native_aa_controls()
local native_items = {
ref.enabled,
ref.pitch[1], ref.pitch[2],
ref.yaw_base,
ref.yaw[1], ref.yaw[2],
ref.yaw_jitter[1], ref.yaw_jitter[2],
ref.body_yaw[1], ref.body_yaw[2],
ref.freestanding_body_yaw,
ref.edge_yaw,
ref.freestanding[1], ref.freestanding[2],
ref.roll
}
for i = 1, #native_items do
if native_items[i] ~= nil then
pcall(ui.set_visible, native_items[i], false)
end
end
end
local Buffer = { } do
Buffer.__index = Buffer
function Buffer:clear()
for k in pairs(self) do
self[k] = nil
end
end
function Buffer:copy(target)
for k, v in pairs(target) do
self[k] = v
end
end
function Buffer:unset()
aa_runtime_state.desync_offset = 0
override.unset(ref.roll)
override.unset(ref.freestanding[2])
override.unset(ref.freestanding[1])
override.unset(ref.edge_yaw)
override.unset(ref.freestanding_body_yaw)
override.unset(ref.body_yaw[2])
override.unset(ref.body_yaw[1])
override.unset(ref.yaw[2])
override.unset(ref.yaw[1])
override.unset(ref.yaw_jitter[2])
override.unset(ref.yaw_jitter[1])
override.unset(ref.yaw_base)
override.unset(ref.pitch[2])
override.unset(ref.pitch[1])
override.unset(ref.enabled)
for item in pairs(applied_native_values) do
applied_native_values[item] = nil
end
native_menu_was_open = false
last_native_mode_signature = nil
end
function Buffer:set()
aa_runtime_state.desync_offset = tonumber(self.body_yaw_offset) or aa_runtime_state.desync_offset or 0
if self.pitch_offset ~= nil then
self.pitch_offset = utils.clamp(
self.pitch_offset, -89, 89
)
end
if self.yaw_offset ~= nil then
self.yaw_offset = utils.normalize(
self.yaw_offset, -180, 180
)
end
if self.jitter_offset ~= nil then
self.jitter_offset = utils.normalize(
self.jitter_offset, -180, 180
)
end
if self.body_yaw_offset ~= nil then
self.body_yaw_offset = utils.clamp(
self.body_yaw_offset, -180, 180
)
end
override_value(ref.enabled, self.enabled)
override_value(ref.pitch[1], self.pitch)
override_value(ref.pitch[2], self.pitch_offset)
override_value(ref.yaw_base, self.yaw_base)
override_value(ref.yaw[1], self.yaw)
override_value(ref.yaw[2], self.yaw_offset)
override_value(ref.yaw_jitter[1], self.yaw_jitter)
override_value(ref.yaw_jitter[2], self.jitter_offset)
override_value(ref.body_yaw[1], self.body_yaw)
override_value(ref.body_yaw[2], self.body_yaw_offset)
override_value(ref.freestanding_body_yaw, self.freestanding_body_yaw)
override_value(ref.edge_yaw, self.edge_yaw)
if self.freestanding == true then
override_value(ref.freestanding[1], true)
override_value(ref.freestanding[2], 'Always on')
elseif self.freestanding == false then
override_value(ref.freestanding[2], nil)
override_value(ref.freestanding[1], false)
else
override_value(ref.freestanding[2], nil)
override_value(ref.freestanding[1], nil)
end
override_value(ref.roll, self.roll)
local menu_open = ui.is_menu_open()
if not menu_open then
native_menu_was_open = false
else
local signature = native_mode_signature(self)
if not native_menu_was_open or signature ~= last_native_mode_signature then
hide_native_aa_controls()
end
native_menu_was_open = true
last_native_mode_signature = signature
end
end
end
setmetatable(buffer, Buffer)
end
local buffer_mods = { } do
local inverts = 0
local yaw_inverts = 0
local inverted = false
local yaw_inverted = false
local delay_ticks = 0
local yaw_delay_ticks = 0
local body_delay_target, body_delay_signature = 1, nil
local yaw_delay_target, yaw_delay_signature = 1, nil
local yaw_flick_timer = 0
local yaw_custom_last_value = nil
local jitter_random_value = 0
local jitter_random_inverts = -1
local skitter = {
-1.00, 0.82, -0.18, 1.00,
-0.64, 0.24, 0.91, -0.36,
0.68, -0.86, 0.12, 0.96,
-0.48, 0.34, -0.94, 0.57
}
local jitter_patterns = {
['2-way'] = { -1.00, 0.78 },
['3-way'] = { -1.00, 0.22, 0.86 },
['5-way'] = { -1.00, -0.38, 0.16, 0.82, -0.12 }
}
local phase_engine = {
packet = -1,
seed = 0,
epoch = 0,
interval = 9
}
local function update_phase_engine()
local packet = tonumber(localplayer.sent_packets) or 0
if phase_engine.packet == packet then return end
phase_engine.packet = packet
phase_engine.epoch = phase_engine.epoch + 1
if phase_engine.epoch >= phase_engine.interval then
local threat = client.current_threat() or 0
phase_engine.seed = (globals.tickcount() * 17 + packet * 13 + threat * 7) % 97
phase_engine.interval = 7 + phase_engine.seed % 9
phase_engine.epoch = 0
end
end
local function phase_index(count, raw_index)
update_phase_engine()
if count <= 1 then return 1 end
local steps = { [2]=1, [3]=2, [4]=3, [5]=2, [12]=5, [16]=7 }
local step = steps[count] or 1
return ((raw_index * step + phase_engine.seed) % count) + 1
end
-- Source-informed Record Phase: advances only on packet-visible phases and
-- de-couples side, magnitude and jitter so it does not collapse into a simple ABAB loop.
local record_phase_holds = { 2, 1, 4, 2, 3, 1, 2, 4, 1, 3, 2, 1, 4 }
local record_phase_sides = { -1, -1, 1, -1, 1, 1, -1, 1, -1, -1, 1, -1, 1 }
local record_phase_magnitudes = {
1.00, 0.64, 0.88, 0.52, 0.97, 0.73, 0.58,
0.92, 0.46, 0.84, 0.61, 0.99, 0.69
}
local record_phase_jitter = {
-0.94, 0.31, 0.79, -0.22, 1.00, -0.61, 0.12,
0.58, -0.82, 0.27, 0.88, -0.47, 0.69
}
local record_phase_delays = { 2, 1, 4, 2, 3, 1, 2, 4, 1, 3, 2, 1, 4 }
local record_phase = { packet = -1, stage = 1, age = 0, signature = nil }
local function get_record_phase_state()
if not localplayer.is_onground then return 4 end
if localplayer.is_crouched then return 3 end
if localplayer.is_moving then return 2 end
return 1
end
local function update_record_phase()
local packet = tonumber(localplayer.sent_packets) or 0
if record_phase.packet == packet then return end
record_phase.packet = packet
local state = get_record_phase_state()
local threat = client.current_threat() or 0
local signature = state * 128 + threat
if record_phase.signature ~= signature then
record_phase.signature = signature
record_phase.stage = ((record_phase.stage - 1 + packet + threat * 3 + state * 5) % #record_phase_holds) + 1
record_phase.age = 0
end
record_phase.age = record_phase.age + 1
local hold = record_phase_holds[record_phase.stage] or 1
if record_phase.age > hold then
record_phase.stage = record_phase.stage % #record_phase_holds + 1
record_phase.age = 1
end
end
local function record_phase_index(step, shift)
update_record_phase()
local count = #record_phase_holds
return (((record_phase.stage - 1) * (step or 1) + (shift or 0)) % count) + 1
end
function buffer_mods:get_yaw_inverted()
return yaw_inverted
end
function buffer_mods:get_yaw_inverts()
return yaw_inverts
end
function buffer_mods:update_inverter()
local source_mode = buffer.body_yaw_source_mode or 'Off'
local delay_mode = buffer.body_delay_mode or 'Default'
local delays = buffer.body_delays or {1, 1}
local count = math.max(2, math.min(10, math.floor(tonumber(buffer.body_delay_count) or 2)))
local chance = utils.clamp(math.floor(tonumber(buffer.body_invert_chance) or 100), 1, 100)

local function choose_delay()
if source_mode == 'Static' or source_mode == 'Off' then
return 1
end

if delay_mode == 'Custom' then
local index = utils.random_int(1, count)
return math.max(1, math.floor(tonumber(delays[index]) or 1))
end

local first = math.max(1, math.floor(tonumber(delays[1]) or 1))
local second = math.max(1, math.floor(tonumber(delays[2]) or first))
if first > second then first, second = second, first end
return utils.random_int(first, second)
end

local sig = {
source_mode,
delay_mode,
tostring(count),
tostring(chance)
}
for i = 1, count do
sig[#sig + 1] = tostring(delays[i] or 1)
end
local signature = table.concat(sig, ':')

if signature ~= body_delay_signature then
body_delay_signature = signature
body_delay_target = choose_delay()
delay_ticks = 0
end

delay_ticks = delay_ticks + 1
if delay_ticks < body_delay_target then return end

delay_ticks = 0
body_delay_target = choose_delay()

-- source exposes an explicit 1..100% invert chance for
-- Jitter / Random / Min-Max.
local should_invert = true
if source_mode ~= 'Static' and source_mode ~= 'Off' then
should_invert = utils.random_int(1, 100) <= chance
end

if should_invert then
inverts = inverts + 1
inverted = not inverted
end
end

function buffer_mods:update_yaw_delay()
local first = math.max(1, math.floor(tonumber(buffer.yaw_delay_min) or 2))
local second = math.max(1, math.floor(tonumber(buffer.yaw_delay_max) or 4))
local mode = buffer.yaw_delay_mode or 'Default'
local low, high = math.min(first, second), math.max(first, second)
local signature = mode .. ':' .. first .. ':' .. second
if mode == 'Custom' then
local custom_count = math.max(1, math.min(12, math.floor(tonumber(buffer.yaw_custom_count) or 1)))
signature = signature .. ':' .. tostring(buffer.yaw_custom_mode or 'Sequential') .. ':' .. custom_count
for i = 1, custom_count do
signature = signature .. ':' .. tostring(buffer.yaw_custom_delays and buffer.yaw_custom_delays[i] or 1)
end
end
local function choose_delay()
if mode == 'Default' then
return first
elseif mode == 'Randomized' then
return utils.random_int(low, high)
elseif mode == 'Alternating' then
return (yaw_inverts % 2 == 0) and first or second
elseif mode == 'Smart' then
local middle = math.floor((first + second) * 0.5 + 0.5)
local pattern = {first, second, middle, first, second}
return pattern[(yaw_inverts % #pattern) + 1]
elseif mode == 'Record Phase' then
local index = ((yaw_inverts * 5 + 3) % #record_phase_delays) + 1
return record_phase_delays[index]
elseif mode == 'Custom' then
local count = math.max(1, math.min(12, math.floor(tonumber(buffer.yaw_custom_count) or 1)))
local delays = buffer.yaw_custom_delays or { }
local custom_mode = buffer.yaw_custom_mode or 'Sequential'
local index
if custom_mode == 'Sequential' then
index = (yaw_inverts % count) + 1
elseif custom_mode == 'Smart Random' then
local available = { }
for i = 1, count do
local value = math.max(1, math.floor(tonumber(delays[i]) or 1))
if value ~= yaw_custom_last_value then available[#available + 1] = value end
end
if #available == 0 then
for i = 1, count do available[#available + 1] = math.max(1, math.floor(tonumber(delays[i]) or 1)) end
end
local value = available[utils.random_int(1, #available)]
yaw_custom_last_value = value
return value
else
index = utils.random_int(1, count)
end
local value = math.max(1, math.floor(tonumber(delays[index]) or 1))
yaw_custom_last_value = value
return value
elseif mode == 'Flick' then
if yaw_flick_timer > 0 then
yaw_flick_timer = yaw_flick_timer - 1
return 1
end
yaw_flick_timer = utils.random_int(3, 6)
return first
end
return first
end
if signature ~= yaw_delay_signature then
yaw_delay_signature = signature
yaw_flick_timer = 0
yaw_custom_last_value = nil
yaw_delay_target = choose_delay()
yaw_delay_ticks = 0
end
yaw_delay_ticks = yaw_delay_ticks + 1
if yaw_delay_ticks < yaw_delay_target then return end
yaw_inverts = yaw_inverts + 1
yaw_inverted = not yaw_inverted
yaw_delay_ticks = 0
yaw_delay_target = choose_delay()
end
function buffer_mods:update_yaw_offset()
if aa_runtime_state.aa_owner ~= 'Builder' then return end
if buffer.yaw_left ~= nil and buffer.yaw_right ~= nil then
local yaw = buffer.yaw_offset or 0
if buffer.yaw_left_delay ~= nil or buffer.yaw_right_delay ~= nil then
local body_yaw_offset = math.abs(buffer.body_yaw_offset)
if not yaw_inverted then yaw = yaw + buffer.yaw_left end
if yaw_inverted then yaw = yaw + buffer.yaw_right end
if buffer.record_phase_body ~= true then
if not yaw_inverted then body_yaw_offset = -body_yaw_offset end
else
body_yaw_offset = buffer.body_yaw_offset
end
buffer.body_yaw = 'Static'
buffer.body_yaw_offset = body_yaw_offset
else
if buffer.body_yaw_offset < 0 then yaw = yaw + buffer.yaw_left end
if buffer.body_yaw_offset > 0 then yaw = yaw + buffer.yaw_right end
end
buffer.yaw_offset = yaw
end
if buffer.yaw_offset ~= nil then
buffer.yaw_offset = wrappers.normalize_yaw(buffer.yaw_offset)
end
end
function buffer_mods:update_yaw_jitter()
if aa_runtime_state.aa_owner ~= 'Builder' then return end
local active_jitter_inverts = inverts
local active_jitter_inverted = inverted
if buffer.yaw_left_delay ~= nil or buffer.yaw_right_delay ~= nil then
active_jitter_inverts = yaw_inverts
active_jitter_inverted = yaw_inverted
end
if buffer.yaw_jitter == 'Offset' then
local yaw = buffer.yaw_offset or 0
local offset = buffer.jitter_offset
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
buffer.yaw_offset = yaw + (active_jitter_inverted and offset or 0)
return
end
if buffer.yaw_jitter == 'Center' then
local yaw = buffer.yaw_offset or 0
local offset = buffer.jitter_offset
if not active_jitter_inverted then
offset = -offset
end
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
buffer.yaw_offset = yaw + offset / 2
return
end
if buffer.yaw_jitter == 'Skitter' then
local index = phase_index(#skitter, active_jitter_inverts)
local multiplier = skitter[index]
local yaw = buffer.yaw_offset or 0
local offset = buffer.jitter_offset
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
buffer.yaw_offset = yaw + (offset * multiplier)
return
end
if buffer.yaw_jitter == 'Record Phase' then
local yaw = buffer.yaw_offset or 0
local offset = math.abs(tonumber(buffer.jitter_offset) or 0)
local index = record_phase_index(7, 4)
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
buffer.yaw_offset = yaw + offset * record_phase_jitter[index]
return
end
if buffer.yaw_jitter == 'Random' then
local yaw = buffer.yaw_offset or 0
local offset = math.abs(tonumber(buffer.jitter_offset) or 0)
if jitter_random_inverts ~= active_jitter_inverts then
jitter_random_inverts = active_jitter_inverts
jitter_random_value = utils.random_int(-offset, offset)
end
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
buffer.yaw_offset = yaw + jitter_random_value
return
end
local pattern = jitter_patterns[buffer.yaw_jitter]
if buffer.yaw_jitter == 'Adaptive' then
local speed = math.sqrt(localplayer.velocity2d_sqr or 0)
local scale
if not localplayer.is_onground then
scale, pattern = 0.78, { -0.72, 0.18, 1.00, -0.33 }
elseif localplayer.is_crouched then
scale, pattern = 0.84, { -1.00, 0.24, 0.88, -0.46 }
elseif speed > 145 then
scale, pattern = 0.70, { -1.00, 0.72 }
elseif speed > 5 then
scale, pattern = 0.86, { -1.00, 0.10, 0.88 }
else
scale, pattern = 1.00, jitter_patterns['5-way']
end
local yaw = buffer.yaw_offset or 0
local offset = (buffer.jitter_offset or 0) * scale
local index = phase_index(#pattern, active_jitter_inverts)
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
buffer.yaw_offset = yaw + offset * pattern[index]
return
end
if pattern ~= nil then
local yaw = buffer.yaw_offset or 0
local offset = buffer.jitter_offset or 0
local index = phase_index(#pattern, active_jitter_inverts)
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
buffer.yaw_offset = yaw + offset * pattern[index]
return
end
if buffer.yaw_jitter == 'X-way' then
local ctx = buffer.way
if ctx ~= nil then
local yaw = buffer.yaw_offset or 0
local offset = buffer.jitter_offset
local index = phase_index(ctx.count, active_jitter_inverts)
local is_custom = ctx.offsets ~= nil
if is_custom then
buffer.yaw_offset = yaw + ctx.offsets[index]
end
if not is_custom then
buffer.yaw_offset = yaw + utils.lerp(
-offset, offset, (index - 1) / (ctx.count - 1)
)
end
end
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
return
end
end
local function neverlose_desync_limit()
-- The Neverlose anti-aim source derives the usable feet-yaw delta from
-- movement/duck state around a 58° base. GameSense Lua does not expose the
-- exact walk_run_transition value, so speed_ratio is used as the local proxy.
local speed = math.sqrt(math.max(0, tonumber(localplayer.velocity2d_sqr) or 0))
local duck = utils.clamp(tonumber(localplayer.duck_amount) or 0, 0, 1)
local max_speed = 260
local me = entity.get_local_player()
if me ~= nil then
local weapon = entity.get_player_weapon(me)
if weapon ~= nil then
local ok, info = pcall(csgo_weapons, weapon)
if ok and info ~= nil then
max_speed = tonumber(info.max_player_speed) or tonumber(info.max_speed) or max_speed
end
end
end
max_speed = math.max(1, max_speed)
local speed_ratio = utils.clamp(speed / (max_speed * 0.52), 0, 1)
local walk_transition = speed_ratio
local scale = (walk_transition * -0.3 - 0.2) * speed_ratio + 1
if duck > 0 then
local duck_speed = utils.clamp(speed / (max_speed * 0.34), 0, 1)
scale = scale + duck * duck_speed * (0.5 - scale)
end
return utils.clamp(58 * scale, 1, 58)
end

function buffer_mods:update_body_yaw()
-- Builder Body Yaw must not overwrite Manual / Safe Head / Freestanding /
-- Anti-Bruteforce / Defensive outputs later in the same setup_command.
if aa_runtime_state.aa_owner ~= 'Builder' then
return
end

local mode = buffer.body_yaw_source_mode or 'Off'
local offset = tonumber(buffer.body_yaw_offset) or 0

buffer.freestanding_body_yaw = false

if mode == 'Off' then
buffer.body_yaw = 'Off'
buffer.body_yaw_offset = 0
return
end

if mode == 'Static' then
buffer.body_yaw = 'Static'
buffer.body_yaw_offset = utils.clamp(offset, -180, 180)
buffer.freestanding_body_yaw = buffer.body_yaw_freestanding == true
return
end

if mode == 'Jitter' then
local magnitude = math.abs(offset)
buffer.body_yaw = 'Static'
buffer.body_yaw_offset = inverted and magnitude or -magnitude
return
end

if mode == 'Random' then
local magnitude = math.abs(offset)
buffer.body_yaw = 'Static'
buffer.body_yaw_offset = utils.random_int(-magnitude, magnitude)
return
end

if mode == 'Min/Max' then
local minimum = tonumber(buffer.body_yaw_offset_min) or 0
local maximum = tonumber(buffer.body_yaw_offset_max) or 0
if maximum < minimum then minimum, maximum = maximum, minimum end
buffer.body_yaw = 'Static'
buffer.body_yaw_offset = utils.random_int(
math.floor(minimum),
math.floor(maximum)
)
return
end

buffer.body_yaw = 'Off'
buffer.body_yaw_offset = 0
end

end
local defensive = { } do
local jitter_toggle = false
local step_counter = 0
local skitter_pattern = { -1, 1, 0, -1, 1, 0, -1, 0, 1, -1, 0, 1 }

local function is_exploit_active()
return reference.is_double_tap_active()
or reference.is_on_shot_antiaim_active()
end

local function update_pitch(buffer_ctx, items)
local value = items.pitch:get()
if value == 'Off' then
return
end

local p_from = items.pitch_offset_1:get()
local p_to = items.pitch_offset_2:get()
local p_speed = items.pitch_speed:get()

if value == 'Static' then
buffer_ctx.pitch = 'Custom'
buffer_ctx.pitch_offset = p_from
return
end

if value == 'Jitter' then
buffer_ctx.pitch = 'Custom'
buffer_ctx.pitch_offset = jitter_toggle and p_to or p_from
return
end

if value == 'Spin' then
local time = (globals.curtime() * p_speed * 0.1) % 1
buffer_ctx.pitch = 'Custom'
buffer_ctx.pitch_offset = utils.lerp(p_from, p_to, time)
return
end

if value == 'Random' then
local low, high = p_from, p_to
if low > high then low, high = high, low end
buffer_ctx.pitch = 'Custom'
buffer_ctx.pitch_offset = utils.random_int(low, high)
return
end

if value == 'Angelic' then
local wave = math.abs(globals.realtime() % 0.3 - 0.15)
local mapped = -89 + (wave / 0.15) * 178
buffer_ctx.pitch = 'Custom'
buffer_ctx.pitch_offset = mapped
return
end
end

local function update_yaw_modifier(buffer_ctx, items)
local mod = items.yaw_modifier:get()
if mod == 'Off' then return end

local mod_offset = items.modifier_offset:get()

if mod == 'Offset' then
local add = jitter_toggle and 0 or mod_offset
buffer_ctx.yaw_offset = (buffer_ctx.yaw_offset or 0) + add
return
end

if mod == 'Center' then
if not items.delay_affect_modifier:get() then
local bit_val = bit.band(step_counter, 1) ~= 0
local prod = bit_val and (mod_offset * 0.5) or (-mod_offset * 0.5)
buffer_ctx.yaw_offset = (buffer_ctx.yaw_offset or 0) + prod
else
buffer_ctx.yaw_left = (buffer_ctx.yaw_left or 0) - mod_offset * 0.5
buffer_ctx.yaw_right = (buffer_ctx.yaw_right or 0) + mod_offset * 0.5
end
buffer_ctx.body_yaw = 'Jitter'
buffer_ctx.body_yaw_offset = 1
return
end

if mod == 'Skitter' then
local mult = skitter_pattern[(step_counter % #skitter_pattern) + 1]
buffer_ctx.yaw_offset = (buffer_ctx.yaw_offset or 0) + mod_offset * mult
return
end
end

local function update_yaw(buffer_ctx, items)
local value = items.yaw:get()
if value == 'Off' then
return
end

local y_speed = items.yaw_speed:get()
local y_offset = items.yaw_offset:get()

buffer_ctx.freestanding = false
buffer_ctx.yaw_left = 0
buffer_ctx.yaw_right = 0
buffer_ctx.yaw_offset = 0
buffer_ctx.delay = 1
buffer_ctx.yaw_jitter = 'Off'
buffer_ctx.jitter_offset = nil

if items.force_target_yaw:get() then
buffer_ctx.yaw_left = -9
buffer_ctx.yaw_right = 6
buffer_ctx.body_yaw = 'Static'
buffer_ctx.body_yaw_offset = -1
end

if value == 'Static' then
buffer_ctx.yaw = '180'
buffer_ctx.yaw_offset = y_offset
elseif value == 'Spin' then
local time = (globals.curtime() * y_speed * 0.1) % 1
local half = y_offset * 0.5
buffer_ctx.yaw = '180'
buffer_ctx.yaw_offset = 180 + utils.lerp(-half, half, time)
elseif value == 'Random' then
local half = math.abs(y_offset * 0.5)
buffer_ctx.yaw = '180'
buffer_ctx.yaw_offset = 180 + utils.random_int(-half, half)
elseif value == 'Left/Right' then
buffer_ctx.yaw = '180'
buffer_ctx.yaw_offset = 0
buffer_ctx.yaw_left = (buffer_ctx.yaw_left or 0) + items.yaw_left:get()
buffer_ctx.yaw_right = (buffer_ctx.yaw_right or 0) + items.yaw_right:get()
elseif value == 'Side-based' then
buffer_ctx.yaw = '180'
buffer_ctx.yaw_offset = 0
local r1 = utils.random_int(-math.abs(y_offset), math.abs(y_offset))
local r2 = utils.random_int(-math.abs(y_offset), math.abs(y_offset))
buffer_ctx.yaw_left = (buffer_ctx.yaw_left or 0) - 90 + r1
buffer_ctx.yaw_right = (buffer_ctx.yaw_right or 0) + 90 + r2
end

if buffer_ctx.body_yaw == nil then
buffer_ctx.body_yaw = 'Static'
buffer_ctx.body_yaw_offset = jitter_toggle and 1 or -1
end

update_yaw_modifier(buffer_ctx, items)
end

local function update_delay(buffer_ctx, items)
local d = 1
if items.delay:get() then
local d1 = items.delays[1]:get()
local d2 = items.delays[2]:get()
local low, high = math.min(d1, d2), math.max(d1, d2)
d = math.max(1, utils.random_int(low, high))
end
buffer_ctx.delay = d
end

function defensive:update_cmd(cmd)
if cmd.chokedcommands == 0 then
jitter_toggle = not jitter_toggle
step_counter = step_counter + 1
end
end

function defensive:apply(cmd, items)
if items == nil or items.enabled == nil or not items.enabled:get() then
return false
end

if items.force_break_lc ~= nil and items.force_break_lc:get() then
cmd.force_defensive = true
end

local is_duck_peek_active = reference.is_duck_peek_assist()
if not is_exploit_active() or is_duck_peek_active then
return false
end

local exp_data = exploit.get()
local def_data = exp_data and exp_data.defensive
local def_ticks = (def_data and def_data.left) or 0
if def_ticks <= 0 then
return false
end

local buffer_ctx = { }
update_pitch(buffer_ctx, items)
update_yaw(buffer_ctx, items)
update_delay(buffer_ctx, items)

buffer.defensive = buffer_ctx
return true
end
end
local current_builder_items, current_builder_state
local builder = { } do
local ref = menu_elements.antiaim.builder
local RANDOM_YAW_DELAY_VALUE = 11
local function update_yaw_base(items)
if items.yaw_base == nil then
return
end
local yaw_base = items.yaw_base:get()
buffer.yaw_base = yaw_base
end
local yaw_random_cache = setmetatable({ }, { __mode = 'k' })
local yaw_custom_delays_cache = { }
local function packet_random(items, key, amount)
amount = math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
if amount == 0 then return 0 end
local cached = yaw_random_cache[items]
if cached == nil or cached.packet ~= localplayer.sent_packets then
cached = { packet = localplayer.sent_packets, values = { } }
yaw_random_cache[items] = cached
end
if cached.values[key] == nil then cached.values[key] = utils.random_int(-amount, amount) end
return cached.values[key]
end
local function update_yaw(items)
if items.yaw_type == nil then
return
end
buffer.yaw_type = items.yaw_type:get()
if buffer.yaw_type == '180' then
buffer.yaw = '180'
local yaw = items.yaw_180_offset:get()
local random = items.yaw_random:get()
if random > 0 then
yaw = yaw + packet_random(items, 'yaw180', random)
end
buffer.yaw_offset = yaw
end
if buffer.yaw_type == 'Between' then
buffer.yaw = '180'
local global_value = items.yaw_between_global:get()
local hold_ticks = math.max(1, items.yaw_between_hold:get())
local switch_ticks = math.max(1, items.yaw_between_switch:get())
local switch_value = items.yaw_between_offset:get()
local total_ticks = hold_ticks + switch_ticks
local phase = globals.tickcount() % total_ticks
local side = buffer_mods:get_yaw_inverted() and 1 or -1
buffer.yaw_offset = global_value
if phase >= hold_ticks then
buffer.yaw_offset = global_value + switch_value * side
end
buffer.yaw_offset = wrappers.normalize_yaw(buffer.yaw_offset)
end
if buffer.yaw_type == 'Left / Right' then
buffer.yaw = '180'
buffer.yaw_left = items.yaw_left_offset:get()
buffer.yaw_right = items.yaw_right_offset:get()
local left_delay = items.yaw_left_delay and items.yaw_left_delay[1]
local right_delay = items.yaw_right_delay and items.yaw_right_delay[1]
buffer.yaw_delay_mode = (items.yaw_delay_mode ~= nil and items.yaw_delay_mode:get()) or 'Default'
buffer.yaw_delay_min = left_delay and left_delay.delay:get() or 1
buffer.yaw_delay_max = right_delay and right_delay.delay:get() or buffer.yaw_delay_min
buffer.yaw_custom_mode = items.yaw_custom_mode and items.yaw_custom_mode:get() or 'Sequential'
buffer.yaw_custom_count = items.yaw_custom_count and items.yaw_custom_count:get() or 1
for i = 1, 12 do
local entry = items.yaw_custom_delays and items.yaw_custom_delays[i]
yaw_custom_delays_cache[i] = entry and entry.delay:get() or 1
end
buffer.yaw_custom_delays = yaw_custom_delays_cache
buffer.yaw_left_delay = buffer.yaw_delay_min
buffer.yaw_right_delay = buffer.yaw_delay_max
end
end
local jitter_random_cache = setmetatable({ }, { __mode = 'k' })
local body_delay_cache = setmetatable({ }, { __mode = 'k' })
local xway_cache = setmetatable({ }, { __mode = 'k' })
local yaw_modifier_random_cache = setmetatable({ }, { __mode = 'k' })
local function get_modifier_slots(items, prefix)
local values_mode = items[prefix .. 'values_mode'] ~= nil and items[prefix .. 'values_mode']:get() or 'Solo'
local slots = { }
if values_mode == 'Custom' and items[prefix .. 'sliders'] ~= nil then
local count = items[prefix .. 'sliders']:get()
for i = 1, count do
local item = items[prefix .. 'slot_' .. i]
if item ~= nil then slots[#slots + 1] = item:get() end
end
elseif values_mode == 'Switch' then
for i = 1, 2 do
local item = items[prefix .. 'slot_' .. i]
if item ~= nil then slots[#slots + 1] = item:get() end
end
else
local item = items[prefix .. 'slot_1']
if item ~= nil then slots[#slots + 1] = item:get() end
end
if #slots == 0 then slots[1] = 0 end
return slots
end
local function apply_modifier_value(items, prefix, current_value, hidden)
local mode_item = items[prefix .. 'mode']
if mode_item == nil then return current_value end
local mode = mode_item:get()
if mode == 'Meta' then
if not localplayer.is_onground then
mode = 'Random'
elseif localplayer.is_crouched then
mode = 'Center'
elseif localplayer.is_moving then
mode = '3-Way'
else
mode = 'Offset'
end
end
local slots = get_modifier_slots(items, prefix)
local variability_item = items[prefix .. 'variability']
local speed_item = items[prefix .. 'speed']
local variability = variability_item ~= nil and variability_item:get() or 0
local speed = speed_item ~= nil and speed_item:get() or 8
local inverts = buffer_mods:get_yaw_inverts()
local function with_variability(v)
local spread = math.floor(math.abs(v) * (variability * 0.01) + 0.5)
if spread <= 0 then return v end
local cache_key = prefix .. ':' .. tostring(localplayer.sent_packets)
local cache = yaw_modifier_random_cache[items]
if cache == nil or cache.key ~= cache_key then
cache = { key = cache_key, delta = utils.random_int(-spread, spread) }
yaw_modifier_random_cache[items] = cache
end
return v + cache.delta
end
if mode == 'Offset' then
return current_value + with_variability(slots[1] or 0)
elseif mode == 'Center' then
return current_value + with_variability((slots[1] or 0) * 0.5)
elseif mode == 'Random' then
local a = slots[1] or 0
local b = slots[2] or -a
if a > b then a, b = b, a end
return current_value + utils.random_int(a, b)
elseif mode == 'Spin' then
local magnitude = math.abs(slots[1] or 45)
local phase = globals.curtime() * (speed * 1.25)
return current_value + math.sin(phase) * magnitude
elseif mode == '3-Way' then
local pattern = { -1, 0, 1 }
local index = phase_index(3, inverts)
local value = slots[index] or (slots[1] or 0) * pattern[index]
return current_value + with_variability(value)
elseif mode == '5-Way' then
local pattern = { -1, -0.5, 0, 0.5, 1 }
local index = phase_index(5, inverts)
local value = slots[index] or (slots[1] or 0) * pattern[index]
return current_value + with_variability(value)
end
return current_value
end
local function read_builder_item(item, fallback)
if item == nil or type(item.get) ~= 'function' then return fallback end
local ok, value = pcall(item.get, item)
if not ok or value == nil then return fallback end
return value
end
local function update_jitter(items)
local yaw_jitter = read_builder_item(items.yaw_jitter, 'Off')
local jitter_offset = tonumber(read_builder_item(items.jitter_offset, 0)) or 0
buffer.yaw_jitter = yaw_jitter
buffer.jitter_offset = jitter_offset
if yaw_jitter == 'X-way' then
local count = utils.clamp(math.floor(tonumber(read_builder_item(items.x_way_ways, 2)) or 2), 2, 5)
local custom = read_builder_item(items.jitter_x_way, 'Default') == 'Custom'
local signature = tostring(count) .. ':' .. tostring(custom)
if custom then
for i = 1, count do signature = signature .. ':' .. tostring(read_builder_item(items['x_way_offset_' .. i], 0)) end
end
local cached = xway_cache[items]
if cached == nil or cached.signature ~= signature then
local ctx = { count = count }
if custom then
ctx.offsets = { }
for i = 1, count do ctx.offsets[i] = tonumber(read_builder_item(items['x_way_offset_' .. i], 0)) or 0 end
end
cached = { signature = signature, context = ctx }
xway_cache[items] = cached
end
buffer.way = cached.context
end
end
local function update_body_yaw(items)
local mode = read_builder_item(items.body_yaw, 'Off')
local allowed = {
['Off'] = true,
['Static'] = true,
['Jitter'] = true,
['Random'] = true,
['Min/Max'] = true
}
if not allowed[mode] then mode = 'Off' end

buffer.body_yaw_source_mode = mode
buffer.body_yaw_offset = tonumber(read_builder_item(items.body_yaw_offset, 0)) or 0
buffer.body_yaw_offset_min = tonumber(read_builder_item(items.body_yaw_offset_min, 0)) or 0
buffer.body_yaw_offset_max = tonumber(read_builder_item(items.body_yaw_offset_max, 0)) or 0
buffer.body_yaw_freestanding = mode == 'Static'
and read_builder_item(items.freestanding_body_yaw, false) == true

buffer.body_delay_mode = read_builder_item(items.body_delay_mode, 'Default')
buffer.body_delay_count = math.max(
2,
math.min(10, math.floor(tonumber(read_builder_item(items.body_delay_count, 2)) or 2))
)

buffer.body_delays = buffer.body_delays or { }
for i = 1, 10 do
local entry = items.body_delays and items.body_delays[i]
buffer.body_delays[i] = entry ~= nil
and math.max(1, math.floor(tonumber(read_builder_item(entry.delay, 1)) or 1))
or 1
end

buffer.body_invert_chance = utils.clamp(
math.floor(tonumber(read_builder_item(items.body_invert_chance, 100)) or 100),
1,
100
)

-- Native mode is finalized by buffer_mods:update_body_yaw().
buffer.body_yaw = mode == 'Off' and 'Off' or 'Static'
buffer.freestanding_body_yaw = false
end
current_builder_items = nil
current_builder_state = nil
rawset(_G, '__aetheryx_current_builder_items', nil)
rawset(_G, '__aetheryx_current_builder_state', nil)
local function update_hidden_builder(cmd)
if aa_runtime_state.aa_owner ~= 'Builder' then return end
local items = current_builder_items
if items == nil or items.angles == nil then return end
local angles = items.angles
if angles.hidden_yaw_enabled == nil or not angles.hidden_yaw_enabled:get() then return end
local should_apply = (cmd.allow_send_packet == false)
or reference.is_double_tap_active()
or reference.is_on_shot_antiaim_active()
or buffer.hidden_yaw_requested == true
if not should_apply then return end
local yaw = buffer.yaw_offset or 0
local side = buffer_mods:get_yaw_inverted() and 1 or -1
local mode = angles.hidden_yaw_mode:get()
if mode == 'Static' then
yaw = yaw + angles.hidden_yaw_static:get()
else
local left = angles.hidden_yaw_left:get()
local right = angles.hidden_yaw_right:get()
if mode == 'Meta Side' and localplayer.is_moving then
yaw = yaw + (side == 1 and right or left) * 0.8
else
yaw = yaw + (side == 1 and right or left)
end
end
if angles.hidden_yaw_modifier_enabled ~= nil and angles.hidden_yaw_modifier_enabled:get() then
yaw = apply_modifier_value(angles, 'hidden_yaw_modifier_', yaw, true)
end
buffer.yaw_offset = yaw
end
rawset(_G, '__aetheryx_update_hidden_builder', update_hidden_builder)

function builder:get(state)
local items = ref[state]
if items == nil then
return nil
end
return items
end
function builder:is_active_ex(items)
local angles = items.angles
if angles == nil then
return false
end
return angles.enabled == nil
or angles.enabled:get()
end
function builder:is_active(state)
local items = self:get(state)
if items == nil then
return false
end
return self:is_active_ex(items)
end
function builder:apply_ex(items)
if items == nil then
return false
end
local angles = items.angles
if angles == nil then
return false
end
buffer.enabled = true
buffer.pitch = 'Default'
update_yaw_base(angles)
update_yaw(angles)
update_jitter(angles)
update_body_yaw(angles)
return true
end
function builder:apply(state)
local items = self:get(state)
if items == nil then
return false, nil
end
if not self:is_active_ex(items) then
return false, items
end
local angles = items.angles
if angles == nil then
return false, nil
end
if not self:apply_ex(items) then
return false, items
end
return true, items
end
function builder:update(cmd)
local states = conditions.get()
local runtime_state = states[#states]

-- The Team combobox is an EDITOR selector only. Live anti-aim always reads
-- the profile matching the local player's actual team, even while the menu
-- is open and the opposite team is being edited.
local me = entity.get_local_player()
local team_num = me ~= nil and entity.get_prop(me, 'm_iTeamNum') or nil
if team_num == 3 then
runtime_builder_team = 'CT'
elseif team_num == 2 then
runtime_builder_team = 'T'
else
runtime_builder_team = active_builder_team
end

local state = states[#states]

if state == nil then
return false, nil, nil
end
local active, items = self:apply(state)
if not active or items == nil then
local shared_active, shared_items = self:apply('Shared')
if not shared_active or shared_items == nil then
return false, nil, nil
end
active = true
items = shared_items
state = 'Shared'
end
return active, items, state
end
end

local safe_head = { } do
local ref = menu_elements.antiaim.features.safe_head
local function selected(name)
return ref.conditions == nil or ref.conditions:get(name)
end
local function get_condition()
if ref == nil or ref.checkbox == nil or not ref.checkbox:get() then
return nil
end
local me = entity.get_local_player()
if me == nil or not entity.is_alive(me) then
return nil
end
local weapon = entity.get_player_weapon(me)
if weapon == nil then
return nil
end
local classname = entity.get_classname(weapon) or ''
local info = csgo_weapons(weapon)
local is_knife = classname == 'CKnife' or classname == 'CKnifeGG' or (info ~= nil and info.type == 'knife' and info.idx ~= 31)
local is_taser = classname == 'CWeaponTaser' or (info ~= nil and info.idx == 31)

-- Requested behavior: holding a knife must never force Safe Head on
-- Standing/Crouching/Moving/etc. Knife Safe Head exists only in Air-Crouch.
local is_air_crouch = not localplayer.is_onground and localplayer.is_crouched
if is_knife then
if not ref.select:get('Knife') or not is_air_crouch then return nil end
return selected('Air crouch knife') and 'Air crouch knife' or nil
end

if is_taser then
if not ref.select:get('Taser') or not is_air_crouch then return nil end
local threat = client.current_threat()
if threat ~= nil then
local mx, my, mz = entity.get_origin(me)
local tx, ty, tz = entity.get_origin(threat)
if mx ~= nil and tx ~= nil then
local dx, dy, dz = tx - mx, ty - my, tz - mz
local dist2 = dx * dx + dy * dy
local height = -dz
if not (height > -20 and dist2 < 500 * 500) then return nil end
end
end
return selected('Air crouch taser') and 'Air crouch taser' or nil
end

return nil
end
function safe_head:update(cmd)
local condition = get_condition()
if condition == nil then
return false
end
if ref.disablers ~= nil then
if ref.disablers:get('Manual active') and aa_runtime_state.manual_direction ~= nil then return false end
if ref.disablers:get('Freestanding active') and reference.is_freestanding() then return false end
end
buffer.enabled = true
buffer.pitch = 'Default'
buffer.yaw_base = 'At targets'
buffer.yaw = '180'
buffer.yaw_offset = condition == 'Air crouch knife' and 37 or 0
buffer.yaw_left = 0
buffer.yaw_right = 0
buffer.yaw_left_delay = nil
buffer.yaw_right_delay = nil
buffer.yaw_jitter = 'Off'
buffer.jitter_offset = 0
buffer.body_yaw = 'Static'
buffer.body_yaw_offset = condition == 'Air crouch knife' and 1 or 0
buffer.freestanding_body_yaw = false
buffer.edge_yaw = false
buffer.freestanding = false
buffer.roll = 0
buffer.defensive = nil
if ref.options ~= nil and ref.options:get('E Spam while active') and cmd ~= nil then
cmd.force_defensive = true
end
return true
end
end

local freestanding = { } do
local ref = menu_elements.antiaim.features.freestanding
local function get_state()
if not localplayer.is_onground then
return 'Air'
end
if localplayer.is_crouched then
return 'Crouching'
end
if localplayer.is_moving then
return reference.is_slow_motion() and 'Slow Walk' or 'Moving'
end
return 'Standing'
end
local function is_enabled()
if not ref.checkbox:get() or not ref.hotkey:get() then
return false
end
if aa_runtime_state.manual_direction ~= nil then
return false
end
return not ref.disablers:get(get_state())
end
local function apply_options()
local items = builder:get('Freestanding')
if items ~= nil and items.override ~= nil and not items.override:get() then
items = nil
end
if items ~= nil then
builder:apply_ex(items)
end
buffer.enabled = true
buffer.yaw_base = 'At targets'
buffer.edge_yaw = false
buffer.freestanding = true
end
function freestanding:update(cmd)
if not is_enabled() then
buffer.freestanding = false
return false
end
local me = entity.get_local_player()
if me == nil or not entity.is_alive(me) then
buffer.freestanding = false
return false
end
apply_options()
return true
end
end
local manual_yaw = { } do
local ref = menu_elements.antiaim.features.manual_yaw
local current_dir = nil
local previous_down = { left=false, right=false, forward=false }
local direction_order = { 'left', 'right', 'forward' }
local dir_rotations = { left=-90, right=90, forward=180 }
local input_initialized = false
local function reset_input_state()
input_initialized = false
for i=1,#direction_order do previous_down[direction_order[i]]=false end
end
local function is_hotkey_active(item)
if item==nil or item.ref==nil then return false end
local ok,active=pcall(ui.get,item.ref)
return ok and active==true
end
local function update_hotkeys()
if not input_initialized then
for i=1,#direction_order do
local dir=direction_order[i]
previous_down[dir]=is_hotkey_active(ref[dir])
end
input_initialized=true
return
end

for i=1,#direction_order do
local dir=direction_order[i]
local active=is_hotkey_active(ref[dir])

-- For Toggle hotkeys, BOTH true->false and false->true mean the user
-- pressed that manual key. Treat the edge as the press instead of waiting
-- for the native toggle to become "on" again.
if active~=previous_down[dir] then
if current_dir==dir then
current_dir=nil
else
current_dir=dir
end
end

previous_down[dir]=active
end
end
function manual_yaw:get()
return current_dir
end
function manual_yaw:update(cmd,team)
if not ref.checkbox:get() then return false end
update_hotkeys()
aa_runtime_state.manual_direction=current_dir
local angle=dir_rotations[current_dir]
if angle==nil then return false end
buffer.enabled=true
buffer.pitch='Default'
buffer.yaw_base='Local view'
buffer.yaw='180'
buffer.edge_yaw=false
buffer.freestanding=false
buffer.roll=0
buffer.defensive=nil
buffer.yaw_offset=angle
buffer.yaw_left=0
buffer.yaw_right=0
buffer.yaw_left_delay=nil
buffer.yaw_right_delay=nil
buffer.yaw_jitter='Off'
buffer.jitter_offset=0
buffer.body_yaw='Static'
if ref.freestanding_body ~= nil and ref.freestanding_body:get() then
-- Manual yaw uses maximum static body setting + freestanding body.
buffer.body_yaw_offset=180
buffer.freestanding_body_yaw=true
else
buffer.body_yaw_offset=58
buffer.freestanding_body_yaw=false
end
return true
end
local function on_enabled(item)
if not item:get() then
current_dir=nil
aa_runtime_state.manual_direction=nil
reset_input_state()
end
end
ref.checkbox:set_callback(on_enabled,true)
end
local avoid_backstab = { } do
local ref = menu_elements.antiaim.features.avoid_backstab
local function is_weapon_knife(weapon)
local weapon_info = csgo_weapons(weapon)
if weapon_info == nil then
return false
end
if weapon_info.idx == 31 then
return false
end
if weapon_info.type ~= 'knife' then
return false
end
return true
end
local function is_player_weapon_knife(player)
local weapon = entity.get_player_weapon(player)
if weapon == nil then
return false
end
return is_weapon_knife(weapon)
end
local function get_targets(player)
local targets = { }
local player_team = entity.get_prop(player, 'm_iTeamNum')
local player_resource = entity.get_player_resource()
for i = 1, globals.maxplayers() do
local is_connected = entity.get_prop(
player_resource, 'm_bConnected', i
)
if is_connected ~= 1 then
goto continue
end
local team = entity.get_prop(
player_resource, 'm_iTeam', i
)
if player == i or player_team == team then
goto continue
end
local is_alive = entity.get_prop(
player_resource, 'm_bAlive', i
)
if is_alive then
table.insert(targets, i)
end
::continue::
end
return targets
end
local function get_backstab_angle(player)
local best_delta = nil
local best_target = nil
local best_distancesqr = math.huge
local origin = vector(
entity.get_origin(player)
)
local me = entity.get_local_player()
if me == nil then
return false
end
local enemies = get_targets(me)
for i = 1, #enemies do
local enemy = enemies[i]
if not is_player_weapon_knife(enemy) then
goto continue
end
local enemy_origin = vector(
entity.get_origin(enemy)
)
local delta = enemy_origin - origin
local distancesqr = delta:lengthsqr()
if distancesqr < best_distancesqr then
best_distancesqr = distancesqr
best_delta = delta
best_target = enemy
end
::continue::
end
return best_target, best_distancesqr, best_delta
end
function avoid_backstab:update()
if not ref.checkbox:get() then
return
end
local me = entity.get_local_player()
if me == nil then
return false
end
if not is_player_weapon_knife(me) then
return false
end
local target, distancesqr, delta = get_backstab_angle(me)
local max_distance = ref.distance:get()
local max_distance_sqr = max_distance * max_distance
if target == nil or distancesqr > max_distance_sqr then
return false
end
local angle = vector(
delta:angles()
)
buffer.enabled = true
buffer.yaw_base = 'Local view'
buffer.yaw = 'Static'
buffer.yaw_offset = angle.y
buffer.freestanding_body_yaw = false
buffer.edge_yaw = false
buffer.freestanding = false
buffer.roll = 0
return true
end
end
-- Combo v1: per-attacker phases, bounded memory and shot-level deduplication.
local anti_bruteforce = { } do
local shared_ref=menu_elements.antiaim.builder.Shared.anti_bruteforce
local context_ref,context_state=shared_ref,'Shared'
local memory=aetheryx_combo_core.new_memory()
local shots,last_hurt={},{}
local legacy,target=nil,nil
local generation=0
local function selected()return context_ref or shared_ref end
local function enabled()local s=selected();return s and s.checkbox:get() end
local function reset()
    memory:clear();shots={};last_hurt={};legacy=nil;target=nil;generation=generation+1
end
local function camera(ent)
    local x,y,z=entity.get_origin(ent)
    if not x then return nil end
    local vz=entity.get_prop(ent,'m_vecViewOffset[2]') or 64
    return vector(x,y,z+vz)
end
local function fired_at(me,shooter,impact)
    local origin=camera(shooter)
    local hx,hy,hz=entity.hitbox_position(me,0)
    if not origin or not hx then return false end
    local head=vector(hx,hy,hz)
    local ray=impact-origin
    local len=ray.x*ray.x+ray.y*ray.y+ray.z*ray.z
    if len<=0.0001 then return false end
    local delta=head-origin
    local projection=utils.clamp((delta.x*ray.x+delta.y*ray.y+delta.z*ray.z)/len,0,1)
    local d=head-(origin+ray*projection)
    return d.x*d.x+d.y*d.y+d.z*d.z<=selected().memory_radius:get()^2
end
local function shot_token(shooter)
    local s=shots[shooter]
    local tick=globals.tickcount()
    if s and tick-s.tick<=16 then return 'fire:'..s.serial end
    return 'impact:'..math.floor(tick/2)
end
local function refresh(s)
    local mode=tostring(s.refresh_modifier:get() or 'Off'):lower()
    local mod=mode=='increase' and utils.random_int(0,5)
        or mode=='decrease' and utils.random_int(-5,0)
        or mode=='adaptive' and utils.random_int(-3,5) or 0
    local off=s.refresh_offset:get() and utils.random_int(-7,13) or 0
    return mod,off
end
local function activate(shooter,reason,token)
    if not enabled() then return end
    local me=entity.get_local_player()
    if not me or not entity.is_alive(me) or not shooter or shooter==me
        or not entity.is_enemy(shooter) or not entity.is_alive(shooter) then return end
    local s=selected()
    local now=globals.realtime()
    local raw=s.duration:get()
    local duration=raw==9 and math.huge or math.max(0.1,raw*0.1)
    local delay=s.enforce_delay:get() and utils.random_int(1,5)*globals.tickinterval() or 0
    local body=tonumber(buffer.body_yaw_offset) or 0
    local yaw=tonumber(buffer.yaw_offset) or 0
    local r,changed
    if s.memory_enabled:get() then
        r,changed=memory:shot(shooter,token,now,s.memory_decay:get(),reason,body,yaw,delay,duration)
    else
        if legacy and legacy.target==shooter and legacy.token==token then return end
        r={phase=0,token=token,time=now,ready=now+delay,expires=now+duration,
            body=body,yaw=yaw,reason=reason,pending=true,target=shooter}
        legacy=r;changed=true
    end
    if not changed then return end
    r.modifier,r.offset=refresh(s)
    target=shooter
end
function anti_bruteforce:set_context(items,state)
    context_ref=items or shared_ref;context_state=state or 'Shared'
end
function anti_bruteforce:update()
    if not enabled() then reset();return false end
    local s=selected()
    local now=globals.realtime()
    local r
    if s.memory_enabled:get() then
        local threat=client.current_threat()
        if threat and entity.is_alive(threat) and entity.is_enemy(threat) then
            -- Do not apply the last attacker's phase to a different threat.
            target=threat
        end
        r=target and memory:get(target,now,s.memory_decay:get())
    else r=legacy;target=r and r.target end
    if not r or now>=r.expires or now<r.ready then return false end
    if not target or not entity.is_alive(target) or entity.is_dormant(target) then return false end
    local magnitude=utils.clamp(math.abs(r.body),1,60)
    if magnitude<5 then magnitude=60 end
    local sign=r.body>=0 and -1 or 1
    local body= r.body+(r.modifier or 0)
    local yaw= r.yaw+(r.offset or 0)
    if r.phase==1 then body=sign*magnitude end
    if r.phase==2 then
        local rhythm=math.max(1,s.memory_rhythm:get())
        local elapsed=math.floor((now-r.time)/globals.tickinterval())
        body=(math.floor(elapsed/rhythm)%2==0 and sign or -sign)*magnitude
    end
    if r.phase==3 then
        body=sign*magnitude
        -- Phase 3 uses a bounded alternative static yaw offset.
        yaw=wrappers.normalize_yaw(r.yaw+sign*35)
    end
    buffer.body_yaw='Static';buffer.body_yaw_offset=wrappers.normalize_yaw(body)
    buffer.freestanding_body_yaw=false;buffer.yaw_offset=wrappers.normalize_yaw(yaw)
    if r.pending then
        local name=entity.get_player_name(target) or 'enemy'
        local text=string.format('AB · %s · phase %d · %s · %s',name,r.phase,r.reason,context_state)
        event_logs.push(text,'info',{event='Bruteforce'})
        if s.memory_log:get() then client.log('[aetheryx] '..text) end
        r.pending=false
    end
    return true
end
utils.event_callback('weapon_fire',function(e)
    local shooter=client.userid_to_entindex(e.userid)
    if shooter and entity.is_enemy(shooter) then
        local old=shots[shooter]
        shots[shooter]={serial=(old and old.serial or 0)+1,tick=globals.tickcount()}
    end
end)
utils.event_callback('bullet_impact',function(e)
    if not enabled() or not e.x or not e.y or not e.z then return end
    local me=entity.get_local_player()
    local shooter=client.userid_to_entindex(e.userid)
    if not me or not entity.is_alive(me) or not shooter or shooter==me
        or not entity.is_enemy(shooter) or entity.is_dormant(shooter) then return end
    if not fired_at(me,shooter,vector(e.x,e.y,e.z)) then return end
    local token=shot_token(shooter)
    local epoch=generation
    client.delay_call(0.04,function()
        if epoch~=generation or entity.get_local_player()~=me then return end
        if last_hurt[shooter]~=token then activate(shooter,'near miss',token) end
    end)
end)
utils.event_callback('player_hurt',function(e)
    if client.userid_to_entindex(e.userid)~=entity.get_local_player() then return end
    local shooter=client.userid_to_entindex(e.attacker)
    if not shooter then return end
    local token=shot_token(shooter);last_hurt[shooter]=token
    activate(shooter,'player hurt',token)
end)
local function clear_player(e)
    local id=client.userid_to_entindex(e.userid)
    if id==entity.get_local_player() then reset();return end
    if id then memory:clear(id);shots[id]=nil;last_hurt[id]=nil;generation=generation+1 end
    if id==target then target=nil;legacy=nil end
end
utils.event_callback('player_spawn',clear_player)
utils.event_callback('player_death',clear_player)
utils.event_callback('player_disconnect',function()reset()end)
utils.event_callback('round_end',reset)
utils.event_callback('round_start',reset)
utils.event_callback('level_init',reset)
utils.event_callback('shutdown',reset)
end
client.log('[Aetheryx] aetheryx Builder migration: Body Yaw + Anti-Bruteforce active')
local function update_antiaim(cmd)
-- Manual input is checked first so switching does not wait behind the
-- complete builder/defensive update path.
if manual_yaw:update(cmd) then
current_builder_items = nil
current_builder_state = 'Manual AA'
rawset(_G, '__aetheryx_current_builder_items', nil)
rawset(_G, '__aetheryx_current_builder_state', 'Manual AA')
aa_runtime_state.aa_owner = 'Manual'
aa_runtime_state.aa_state = 'Manual AA'
return
end

local active, items, state = builder:update(cmd)
current_builder_items = items
current_builder_state = state
rawset(_G, '__aetheryx_current_builder_items', items)
rawset(_G, '__aetheryx_current_builder_state', state)
aa_runtime_state.aa_owner = 'Builder'
aa_runtime_state.aa_state = state or conditions.get()[1] or 'Shared'
local bruteforce_items = items ~= nil and items.anti_bruteforce or nil
local bruteforce_state = state
local shared_items = menu_elements.antiaim.builder.Shared.anti_bruteforce
if bruteforce_items == nil
or not bruteforce_items.checkbox:get() and shared_items.checkbox:get() then
bruteforce_items = shared_items
bruteforce_state = 'Shared'
end
anti_bruteforce:set_context(
bruteforce_items,
bruteforce_state
)
if avoid_backstab:update() then
aa_runtime_state.aa_owner = 'Backstab'
aa_runtime_state.aa_state = 'Avoid backstab'
return
end
if safe_head:update(cmd) then
aa_runtime_state.aa_owner = 'Safe Head'
aa_runtime_state.aa_state = 'Safe Head'
return
end
if freestanding:update(cmd) then
aa_runtime_state.aa_owner = 'Freestanding'
aa_runtime_state.aa_state = 'Freestanding'
return
end
if anti_bruteforce:update() then
aa_runtime_state.aa_owner = 'Anti bruteforce'
aa_runtime_state.aa_state = bruteforce_state or state or 'Shared'
return
end
if active and items ~= nil and items.defensive ~= nil
and defensive:apply(cmd, items.defensive) then
aa_runtime_state.aa_owner = 'Defensive'
aa_runtime_state.aa_state = state or 'Defensive'
return
end
end
local function update_defensive(cmd)
if aa_runtime_state.aa_owner ~= 'Builder' and aa_runtime_state.aa_owner ~= 'Defensive' then return false end
local list = buffer.defensive
local is_exploit_active = (
reference.is_double_tap_active()
or reference.is_on_shot_antiaim_active()
)
if reference.is_duck_peek_assist() then
is_exploit_active = false
end
if not is_exploit_active then
return false
end
local exp_data = exploit.get()
local defensive = exp_data.defensive
local is_valid = (
list ~= nil and
defensive.left > 0
)
if not is_valid then
return
end
buffer:copy(list)
end
local function packet_custom_is_safe(cmd)
if not buffer.custom_packet_active or aa_runtime_state.aa_owner ~= 'Builder' then
return false
end
local me = entity.get_local_player()
if me == nil or not entity.is_alive(me) then
return false
end
if cmd.in_attack == 1 or cmd.in_attack2 == 1 or cmd.in_use == 1 then
return false
end
if entity.get_prop(me, 'm_MoveType') == 9 then
return false
end
local weapon = entity.get_player_weapon(me)
if weapon ~= nil then
local throw_time = entity.get_prop(weapon, 'm_fThrowTime')
if throw_time ~= nil and throw_time ~= 0 then
return false
end
end
if reference.is_double_tap_active()
or reference.is_on_shot_antiaim_active()
or reference.is_duck_peek_assist() then
return false
end
return true
end
local packet_custom_runtime = {
active = false,
stored_real_offset = 0,
real_command = 0,
fake_command = 0
}
local function reset_packet_custom_runtime()
packet_custom_runtime.active = false
packet_custom_runtime.stored_real_offset = 0
packet_custom_runtime.real_command = 0
packet_custom_runtime.fake_command = 0
end
local function update_packet_custom(cmd)
rawset(_G, '__aetheryx_custom_packet_active', false)
if not buffer.custom_packet_active then
reset_packet_custom_runtime()
return
end
if not packet_custom_is_safe(cmd) then
reset_packet_custom_runtime()
return
end
rawset(_G, '__aetheryx_custom_packet_active', true)
local adaptive_limit = 58
local offset = utils.clamp(
tonumber(buffer.custom_packet_offset) or 0,
-adaptive_limit,
adaptive_limit
)
local base_offset = utils.normalize(
tonumber(buffer.yaw_offset) or 0,
-180,
180
)
local choked = tonumber(cmd.chokedcommands) or 0
local command_number = tonumber(cmd.command_number) or 0
if not packet_custom_runtime.active or choked == 0 then
packet_custom_runtime.active = true
packet_custom_runtime.stored_real_offset = base_offset
packet_custom_runtime.real_command = command_number
cmd.no_choke = false
cmd.allow_send_packet = false
buffer.yaw_offset = packet_custom_runtime.stored_real_offset
buffer.body_yaw = 'Off'
buffer.body_yaw_offset = 0
buffer.freestanding_body_yaw = false
return
end
packet_custom_runtime.fake_command = command_number
cmd.no_choke = true
cmd.allow_send_packet = true
buffer.yaw_offset = utils.normalize(
packet_custom_runtime.stored_real_offset + offset,
-180,
180
)
buffer.body_yaw = 'Static'
buffer.body_yaw_offset = 0
buffer.freestanding_body_yaw = false
end
local function update_buffer(cmd)
defensive:update_cmd(cmd)
update_defensive(cmd)
if cmd.chokedcommands == 0 then
buffer_mods:update_inverter()
buffer_mods:update_yaw_delay()
end
buffer_mods:update_body_yaw()
buffer_mods:update_yaw_jitter()
buffer_mods:update_yaw_offset()
local hidden_builder_update = rawget(_G, '__aetheryx_update_hidden_builder')
if hidden_builder_update ~= nil then
hidden_builder_update(cmd)
end
update_packet_custom(cmd)
end
local function on_shutdown()
buffer:unset()
end
local function on_setup_command(cmd)
buffer:clear()
update_antiaim(cmd)
update_buffer(cmd)
buffer:set()
end
utils.event_callback('shutdown', on_shutdown)
utils.event_callback('setup_command', on_setup_command)
end
local aetheryx_fast_ladder do
local ref = menu_elements.antiaim.features.fast_ladder
local MOVETYPE_LADDER = 9
local function is_throwing_grenade(weapon)
local weapon_info = csgo_weapons(weapon)
if weapon_info == nil or weapon_info.type ~= 'grenade' then return false end
local throw_time = entity.get_prop(weapon, 'm_fThrowTime')
return throw_time ~= nil and throw_time ~= 0
end
local function on_setup_command(cmd)
local me = entity.get_local_player()
if me == nil or not entity.is_alive(me) then return end
local movetype = entity.get_prop(me, 'm_MoveType')
if movetype ~= MOVETYPE_LADDER then return end
local weapon = entity.get_player_weapon(me)
if weapon == nil or is_throwing_grenade(weapon) then return end
local nx, ny, nz = entity.get_prop(me, 'm_vecLadderNormal')
if nx == nil or ny == nil or nz == nil then return end
local forward = vector(nx, ny, nz)
if forward:lengthsqr() == 0 then return end
local camera_pitch, camera_yaw = client.camera_angles()
if camera_pitch == nil or camera_yaw == nil then return end
local angle = vector(forward:angles())
local delta_yaw = utils.normalize(angle.y - camera_yaw + 180, -180, 180)
local delta_pitch = utils.clamp(angle.x - camera_pitch, -89, 89)
local abs_yaw = math.abs(delta_yaw)
local pitch = 89
local yaw_offset = -90
local looking_down = delta_pitch < -45
local looking_right = delta_yaw > 0
local side_move = cmd.sidemove > 0
local forward_move = cmd.forwardmove > 0
cmd.yaw = math.floor((tonumber(cmd.yaw) or camera_yaw) + 0.5)
cmd.roll = 0
if abs_yaw > 70 and abs_yaw < 135 then
if cmd.forwardmove ~= 0 or cmd.sidemove == 0 then return end
if not looking_right then yaw_offset = -yaw_offset end
if looking_right then side_move = not side_move end
cmd.in_back = side_move and 1 or 0
cmd.in_forward = side_move and 0 or 1
if looking_right then side_move = not side_move end
cmd.in_moveleft = side_move and 1 or 0
cmd.in_moveright = side_move and 0 or 1
cmd.pitch = pitch
cmd.yaw = utils.normalize(angle.y + yaw_offset, -180, 180)
return
end
if cmd.sidemove ~= 0 or cmd.forwardmove == 0 then return end
if not looking_right then yaw_offset = -yaw_offset end
if not looking_down then forward_move = not forward_move end
cmd.in_back = forward_move and 0 or 1
cmd.in_forward = forward_move and 1 or 0
if not looking_right then forward_move = not forward_move end
cmd.in_moveleft = forward_move and 1 or 0
cmd.in_moveright = forward_move and 0 or 1
cmd.pitch = pitch
cmd.yaw = utils.normalize(angle.y + yaw_offset, -180, 180)
end
local function update_callback(item)
utils.event_callback('setup_command', on_setup_command, item:get())
end
ref:set_callback(update_callback, true)
end

-- Lagrecord Update runtime -------------------------------------------------
-- Exact packet cycle from Spectre, with Aetheryx safety/ownership guards.
local aetheryx_lagrecord_update do
local ref = menu_elements.other.lagrecord_update
local tracked_records = { }
local last_validation_reason = 'valid'

local function clear_tracked_records()
tracked_records = { }
last_validation_reason = 'valid'
end

local function update_enemy_records()
local enemies = entity.get_players(true) or { }
local tickinterval = globals.tickinterval()
for i = 1, #enemies do
local ent = enemies[i]
local simtime = entity.get_prop(ent, 'm_flSimulationTime')
local ox, oy, oz = entity.get_prop(ent, 'm_vecOrigin')
if simtime ~= nil and ox ~= nil and oy ~= nil and oz ~= nil then
local record = tracked_records[ent]
if record == nil then
tracked_records[ent] = {
simtime = simtime, x = ox, y = oy, z = oz,
regressed = false, teleported = false, choke_ticks = 0
}
elseif simtime ~= record.simtime then
local delta_time = simtime - record.simtime
local dx, dy, dz = ox - record.x, oy - record.y, oz - record.z
local distance_sqr = dx * dx + dy * dy + dz * dz
local limit = tonumber(ref.teleport_distance:get()) or 64
record.regressed = delta_time < -(tickinterval * 0.5)
record.teleported = distance_sqr > limit * limit
record.choke_ticks = math.max(0, math.floor(math.abs(delta_time) / tickinterval + 0.5) - 1)
record.simtime, record.x, record.y, record.z = simtime, ox, oy, oz
end
end
end
end

local function validate_current_threat()
if not ref.validate_records:get() then return true, 'disabled' end
local threat = client.current_threat()
if threat == nil or threat == 0 or not entity.is_alive(threat) then return true, 'no target' end
local record = tracked_records[threat]
if record == nil then return true, 'collecting' end
local tickinterval = globals.tickinterval()
local age_ticks = math.max(0, math.floor((globals.curtime() - record.simtime) / tickinterval + 0.5))
local max_age = tonumber(ref.max_record_age:get()) or 16
if record.regressed then return false, 'regressed' end
if ref.reject_teleport:get() and record.teleported then return false, 'teleport' end
if age_ticks > max_age then return false, 'outdated' end
if record.choke_ticks > max_age then return false, 'high lag' end
return true, 'valid'
end

local function validate_shot(cmd)
if not ref.enabled:get() or not ref.validate_records:get() then return end
if cmd.in_attack ~= 1 then return end
local me = entity.get_local_player()
if me == nil or not entity.is_alive(me) then return end
local weapon = entity.get_player_weapon(me)
if weapon == nil then return end
local info = csgo_weapons(weapon)
if info ~= nil and (info.type == 'grenade' or info.type == 'knife' or info.type == 'c4') then return end
local valid, reason = validate_current_threat()
last_validation_reason = reason
if not valid then
cmd.in_attack = 0
end
end

local function safe_to_control_packets(cmd)
if ref == nil or not ref.enabled:get() then return false end
if rawget(_G, '__aetheryx_custom_packet_active') == true then return false end
local me = entity.get_local_player()
if me == nil or not entity.is_alive(me) then return false end
if reference.is_duck_peek_assist() then return false end
if cmd.in_attack == 1 or cmd.in_attack2 == 1 or cmd.in_use == 1 then return false end
if entity.get_prop(me, 'm_MoveType') == 9 then return false end
local weapon = entity.get_player_weapon(me)
if weapon ~= nil then
local throw_time = entity.get_prop(weapon, 'm_fThrowTime')
if throw_time ~= nil and throw_time ~= 0 then return false end
end
return true
end


local function on_setup_command(cmd)
validate_shot(cmd)
if not safe_to_control_packets(cmd) then return end
local choked = tonumber(cmd.chokedcommands) or 0
if ref.method:get() == 'Network errors' then
if choked == 0 then
cmd.allow_send_packet = false
else
cmd.allow_send_packet = true
end
else
if choked < 2 then
cmd.no_choke = false
cmd.allow_send_packet = false
else
cmd.no_choke = true
cmd.allow_send_packet = true
end
end
end

__aetheryx_runtime.set('net_update_end', update_enemy_records)
__aetheryx_runtime.set('level_init', clear_tracked_records)
__aetheryx_runtime.set('setup_command', on_setup_command)
__aetheryx_runtime.set('shutdown', function()
clear_tracked_records()
rawset(_G, '__aetheryx_custom_packet_active', false)
end)
end

-- Apply native compact geometry after Aetheryx has updated menu visibility/layout.
-- Restored in v11: without this callback GameSense rebuilds inline controls at
-- their stock full width after reload.
__aetheryx_runtime.set('paint_ui', aetheryx_native_inline.apply)


-- Aetheryx Peek Telemetry v2.1.0, GameSense / CS:GO Legacy.
-- Receives forecasts and logs actual aim_fire events. Does NOT drive ragebot or attack.
;(function()
local old = rawget(_G, '__aetheryx_peek_receiver_v2')
if old and old.cleanup then pcall(old.cleanup) end
local api = { callbacks = {} }
rawset(_G, '__aetheryx_peek_receiver_v2', api)
local enabled = ui.new_checkbox('LUA','B','Aetheryx peek telemetry')
local ticks = ui.new_slider('LUA','B','Peek horizon',1,4,3,true,'t')
local logs = ui.new_checkbox('LUA','B','Peek console logs')
local indicator = ui.new_checkbox('LUA','B','Peek status')
local test = ui.new_button('LUA','B','Test peek bridge',function()
    if ui.get(enabled) then client.exec('sm_athpeek_test')
    else client.color_log(170,200,255,'[Aetheryx Peek] Enable telemetry first.') end
end)
ui.set(logs,true)
local state = { token='', seq=0, seen=0, attempt=-10, ack=false, sent=false, hints={}, recent={}, shots={}, last_notice=-10, last_ack=-10, test_seen=0, wire_candidates=0, wire_matches=0 }
local kinds={H=true,V=true,C=true,S=true,M=true,K=true,T=true,B=true}
local function now() return globals.realtime() end
local function clear() state.hints={};state.recent={};state.shots={} end
local function log(text,force)
    if force or ui.get(logs) then client.color_log(170,200,255,'[Aetheryx Peek] '..text) end
end
local function name(index)
    if not index or index<=0 then return '?' end
    local s=entity.get_player_name(index) or '?'
    return tostring(s):gsub('[%c]',' '):sub(1,48)
end
local function parse(text)
    if type(text)~='string' or #text>160 then return nil end
    local tok,seq,tick,uid,kind,lead,interval=text:match('^ATHPEEK2|(%d+)|(%d+)|(%d+)|(%d+)|([A-Z])|(-?%d+)|([%d%.]+)$')
    if not tok or tok~=state.token or #tok<6 or #tok>20 or not kinds[kind] then return nil end
    seq,tick,uid,lead,interval=tonumber(seq),tonumber(tick),tonumber(uid),tonumber(lead),tonumber(interval)
    if not seq or seq<=state.seq or seq>2147483647 or tick>2147483647 or uid>65535 then return nil end
    if not interval or interval<0.001 or interval>0.1 or lead< -1 or lead>4 then return nil end
    if kind=='H' and (uid<=0 or lead<1 or lead>ui.get(ticks)) then return nil end
    return {seq=seq,tick=tick,uid=uid,kind=kind,lead=lead,interval=interval}
end
local function packet(e)
    if not ui.get(enabled) then return end
    local p=parse(e.text);if not p then return end
    if state.seq>0 and p.seq>state.seq+1 then log('WIRE GAP: '..(p.seq-state.seq-1)..' records not received; do not infer missing shots.') end
    state.seq=p.seq;state.seen=now()
    if not state.ack then
        state.ack=true
        log('BRIDGE OK v2.1; network snapshot received; forecast only.',true)
    end
    if now()-state.last_ack>=1 or p.kind=='T' then
        client.exec('sm_athpeek_ack '..state.token..' '..p.seq);state.last_ack=now()
    end
    if p.kind=='K' then
        local was=state.ack;state.ack=true
        if not was then log('BRIDGE OK; server interval '..string.format('%.2fms',p.interval*1000)..'; forecast only.',true) end
    elseif p.kind=='T' then log('BRIDGE TEST OK. Event received from your server.',true)
    elseif p.kind=='C' then state.hints={};state.recent={}
    elseif p.kind=='H' then
        local target=client.userid_to_entindex(p.uid);if not target or target<=0 or not entity.is_alive(target) then return end
        local previous=state.recent[p.uid]
        state.hints[p.uid]={target=target,received=now(),eta=p.lead,server_tick=p.tick,interval=p.interval,last_log=previous and previous.last_log or -10}
        state.recent[p.uid]=state.hints[p.uid]
        if not previous or now()-previous.last_log>0.5 then
            log(string.format('HINT %s: estimated opening +%dt; server_tick=%d',name(target),p.lead,p.tick))
            state.hints[p.uid].last_log=now()
        end
    elseif p.kind=='V' then
        state.hints[p.uid]=nil
        log('OPEN '..name(client.userid_to_entindex(p.uid))..': server ray observed open; tick='..p.tick)
    elseif p.kind=='S' then
        log('SERVER FIRE: hint_target='..name(client.userid_to_entindex(p.uid))..'; tick='..p.tick..' (not proof of ragebot target)')
    elseif p.kind=='M' then
        local target=name(client.userid_to_entindex(p.uid))
        if p.lead<0 then log('MEASURE '..target..': opening not observed within horizon / measurement cancelled.')
        elseif p.lead==0 then log('MEASURE '..target..': server ray already open at weapon_fire.')
        else log(string.format('MEASURE %s: weapon_fire -%dt before first observed open ray; not a future hit.',target,p.lead)) end
    end
end
local wire_kinds={[1]='H',[2]='V',[3]='C',[4]='S',[5]='M',[6]='K',[7]='T',[8]='B'}
local function read_int(ent,key,low,high)
    local ok,v=pcall(entity.get_prop,ent,key)
    if not ok or type(v)~='number' or v~=v then return nil end
    local n=math.floor(v+0.5)
    if math.abs(v-n)>0.01 or n<low or n>high then return nil end
    return n
end
local function net_update()
    if not ui.get(enabled) or state.token=='' then return end
    local me=entity.get_local_player();if not me then return end
    local records={}
    state.wire_candidates=0;state.wire_matches=0
    for _,ent in ipairs(entity.get_all('CSprite') or {}) do
        local owner=entity.get_prop(ent,'m_hOwnerEntity')
        if owner==me then state.wire_candidates=state.wire_candidates+1 end
        local nonce=owner==me and read_int(ent,'m_flScaleTime',100000,8000000) or nil
        if owner==me and nonce and tostring(nonce)==state.token then
            state.wire_matches=state.wire_matches+1
            local seq=read_int(ent,'m_flBrightnessTime',1,8000000)
            local data=read_int(ent,'m_flHDRColorScale',0,8388607)
            local tick=read_int(ent,'m_clrRender',0,16777215)
            if seq and seq>state.seq and data and tick then
                local uid=math.floor(data/128)
                local tail=data%128
                local lead=math.floor(tail/16)-1
                local kind=wire_kinds[tail%16]
                local interval=globals.tickinterval()
                if kind then
                    records[#records+1]={seq=seq,text=table.concat({'ATHPEEK2',state.token,seq,tick,uid,kind,lead,string.format('%.6f',interval)},'|')}
                end
            end
        end
    end
    table.sort(records,function(a,b)return a.seq<b.seq end)
    local latest=records[#records]
    local latest_tick=latest and tonumber(latest.text:match('^ATHPEEK2|%d+|%d+|(%d+)|'))
    for _,r in ipairs(records) do
        local tick,kind=r.text:match('^ATHPEEK2|%d+|%d+|(%d+)|%d+|([A-Z])|')
        if kind~='H' or not latest_tick or (latest_tick-tonumber(tick))%16777216<=ui.get(ticks)+1 then packet(r) end
    end
end
local function find_hint(target)
    local best
    for uid,h in pairs(state.recent) do
        if now()-h.received>0.20 or client.userid_to_entindex(uid)~=h.target then state.recent[uid]=nil;state.hints[uid]=nil
        elseif h.target==target and (not best or h.received>best.received) then best=h end
    end
    return best
end
local function aim_fire(e)
    if not ui.get(enabled) then return end
    local h=find_hint(e.target);if not h then return end
    state.shots[e.id]={target=e.target,time=now()}
    log(string.format('RAGE FIRE id=%s target=%s; received_hint=+%dt age=%.0fms; extrapolated=%s; backtrack_raw=%s',
        tostring(e.id),name(e.target),h.eta,(now()-h.received)*1000,tostring(e.extrapolated==true),tostring(e.backtrack or '?')))
    -- No assertion that the ragebot used the hint or that the shot was successful.
end
local function result(e,hit)
    if not ui.get(enabled) then return end
    local shot=state.shots[e.id];if not shot then return end
    state.shots[e.id]=nil
    if hit then log('HIT id='..tostring(e.id)..' '..name(e.target)..' damage='..tostring(e.damage or '?'))
    else log('MISS id='..tostring(e.id)..' '..name(e.target)..' reason='..tostring(e.reason or '?')) end
end
local function connected() return entity.get_local_player()~=nil end
local function handshake()
    if not connected() then return end
    state.token=tostring(client.random_int(100000,8000000))
    state.seq=0;state.ack=false;state.last_ack=-10;state.test_seen=0;state.attempt=now();clear();state.sent=true
    client.exec('sm_athpeek_hello '..state.token..'; sm_athpeek_ticks '..ui.get(ticks)..'; sm_athpeek on')
end
local function visibility()
    local on=ui.get(enabled)
    ui.set_visible(ticks,on);ui.set_visible(logs,on);ui.set_visible(indicator,on);ui.set_visible(test,on)
end
local function settings()
    visibility();clear();state.ack=false;state.seen=0;state.attempt=-10
    if ui.get(enabled) then handshake()
    elseif state.sent then client.exec('sm_athpeek off');state.sent=false end
end
local function paint_ui()
    if not ui.get(enabled) then return end
    local t=now()
    for id,s in pairs(state.shots) do if t-s.time>10 then state.shots[id]=nil end end
    find_hint(-1)
    local me=entity.get_local_player()
    local alive=me and entity.is_alive(me)
    if connected() and (not state.ack or (alive and t-state.seen>2.5)) and t-state.attempt>=3 then
        if t-state.last_notice>=10 and state.attempt>=0 then
            log(string.format('Bridge unconfirmed / idle: local owned_sprites=%d token_matches=%d. Check v2.1 on BOTH sides and run only one receiver.',state.wire_candidates,state.wire_matches),true)
            state.last_notice=t
        end
        handshake()
    end
end
local function paint()
    if not ui.get(enabled) or not ui.get(indicator) then return end
    local active=false
    for _,h in pairs(state.hints) do if now()-h.received<=0.20 then active=true;break end end
    if active then renderer.indicator(170,200,255,255,'PEEK HINT')
    elseif state.ack and now()-state.seen<2.5 then renderer.indicator(160,180,190,255,'PEEK LINK')
    else renderer.indicator(140,140,140,255,'PEEK IDLE') end
end
local function register(event,fn)
    local ok,err=pcall(client.set_event_callback,event,fn)
    if ok then api.callbacks[#api.callbacks+1]={event,fn}
    else log('Callback unavailable '..event..': '..tostring(err),true) end
end
function api.cleanup()
    if state.sent then pcall(client.exec,'sm_athpeek off') end
    for _,cb in ipairs(api.callbacks) do pcall(client.unset_event_callback,cb[1],cb[2]) end
    api.callbacks={}
end
register('net_update_end',net_update)
register('aim_fire',aim_fire)
register('aim_hit',function(e)result(e,true)end)
register('aim_miss',function(e)result(e,false)end)
register('paint_ui',paint_ui);register('paint',paint)
register('level_init',function() clear();state.ack=false;state.token='';state.seq=0;state.attempt=-10 end)
register('player_connect_full',function(e)
    if client.userid_to_entindex(e.userid or 0)==entity.get_local_player() then state.ack=false;state.attempt=-10;clear() end
end)
register('round_start',clear)
register('player_death',function(e)
    local index=client.userid_to_entindex(e.userid or 0)
    if index==entity.get_local_player() then clear() else state.hints[e.userid]=nil;state.recent[e.userid]=nil end
end)
register('shutdown',api.cleanup)
ui.set_callback(enabled,settings);ui.set_callback(ticks,settings)
visibility()
end)()
