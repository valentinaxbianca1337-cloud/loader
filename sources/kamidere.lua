local ffi = require 'ffi'
local vector = require 'vector'

local base64 = require 'gamesense/base64'
local clipboard = require 'gamesense/clipboard'

local c_entity = require 'gamesense/entity'
local csgo_weapons = require 'gamesense/csgo_weapons'
local trace = require 'gamesense/trace'
local localize = require 'gamesense/localize'

local http = require 'gamesense/http'
local websockets = require 'gamesense/websockets'

local inspect = require 'gamesense/inspect'

local function DUMMY(...)
    return ...
end

local function contains(list, value)
    for i = 1, #list do
        if list[i] == value then
            return i
        end
    end

    return nil
end

local function round(x)
    return math.floor(x + 0.5)
end

local script = { } do
    script.name = 'Kamibebra'
    script.build = 'Debug'
    script.user = _USER_NAME or 'admin'
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
        return str
    end

    function utils.clamp(x, min, max)
        return math.max(min, math.min(x, max))
    end

    function utils.event_callback(event_name, callback, value)
        local fn = value == false
            and client.unset_event_callback
            or client.set_event_callback

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

    reference.visuals = {
        effects = {
            remove_scope_overlay = ui.reference(
                'Visuals', 'Effects', 'Remove scope overlay'
            )
        }
    }

    reference.misc = {
        miscellaneous = {
            draw_console_output = ui.reference(
                'Misc', 'Miscellaneous', 'Draw console output'
            ),

            ping_spike = {
                ui.reference('Misc', 'Miscellaneous', 'Ping spike')
            }
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
        return ui.get(reference.ragebot.aimbot.minimum_damage_override[3])
    end

    function reference.get_minimum_damage()
        return ui.get(reference.ragebot.aimbot.minimum_damage)
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
        return ui.get(reference.ragebot.aimbot.minimum_damage_override[1])
            and ui.get(reference.ragebot.aimbot.minimum_damage_override[2])
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
                list[i](...)
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

            -- wtf is that
            ui.set_callback(item, function()
                for i = 1, #list do
                    list[i](item)
                end
            end)

            lookup[item] = list
        end

        local index = contains(lookup[item])

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
    local FILE = PATH .. '\\emberlash_db.dat'

    local store = { }

    local function read_file()
        return readfile(FILE)
    end

    local function write_file(str)
        writefile(FILE, str)
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
        local ok, result = pcall(
            base64.decode, data, BASE64_KEY
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

    local function write_storage(data)
        local ok, result = encode_data(data)

        if not ok then
            logging.error(
                'Unable to encode data'
            )

            return false
        end

        write_file(result)

        return true
    end

    local function parse_storage()
        local content = read_file()

        -- if can't read file, create
        -- new one with empty database
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
            'emberlash_%s_', result
        )
    end

    function config_system.decode(str)
        local data = str:match(
            '%emberlash%_(.-)_'
        )

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

        for k, v in pairs(data) do
            if categories ~= nil and keys[k] == nil then
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

            local values = { }

            for m, n in pairs(v) do
                values[m] = get_item_value(n)
            end

            list[k] = values

            ::continue::
        end

        return list
    end
end

local menu = { } do
    local event_bus = event_system:new()

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
            local have_update_callback = (
                self.type ~= 'hotkey' and
                self.type ~= 'textbox' and
                self.type ~= 'unknown'
            )

            if not have_update_callback then
                return ui.get(self.ref)
            end

            if key ~= nil then
                return self.key_values[key] ~= nil
            end

            return unpack(self.value)
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
                list[i](self)
            end
        end
    end

    -- The extended per-state delay controls are created once for every AA
    -- condition. Keeping all of them in Anti-aimbot angles exceeds the
    -- client's usable control capacity for that panel and prevents clicks on
    -- unrelated Feature checkboxes. Put only those extended Builder controls
    -- in AA > Other; the normal AA/Feature controls stay in their original
    -- Anti-aimbot angles location.
    local EXTENDED_BUILDER_KEYS = {
        'yaw_random',
        'yaw_left_random',
        'yaw_right_random',
        'yaw_left_delay_mode',
        'yaw_left_delay_min',
        'yaw_left_delay_max',
        'yaw_right_delay_mode',
        'yaw_right_delay_min',
        'yaw_right_delay_max',
        'jitter_delay_min',
        'jitter_delay_max',
        'sway_cycle'
    }

    local function is_extended_builder_control(name)
        if type(name) ~= 'string' then
            return false
        end

        for i = 1, #EXTENDED_BUILDER_KEYS do
            if string.find(name, EXTENDED_BUILDER_KEYS[i], 1, true) ~= nil then
                return true
            end
        end

        return false
    end

    function menu.new(fn, ...)
        local argv, argc = { }, select('#', ...)

        for i = 1, argc do
            argv[i] = select(i, ...)
        end

        if argv[1] == 'AA'
            and argv[2] == 'Anti-aimbot angles'
            and is_extended_builder_control(argv[3]) then
            argv[2] = 'Other'
        end

        if fn == ui.new_button and type(argv[4]) ~= 'function' then
            argv[4] = DUMMY
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

local menu_logic = { } do
    local item_data = { }
    local item_list = { }

    local logic_events = event_system:new()

    function menu_logic.get_event_bus()
        return logic_events
    end

    function menu_logic.set(item, value)
        if item == nil or item.ref == nil then
            return
        end

        item_data[item.ref] = value
    end

    function menu_logic.force_update()
        for i = 1, #item_list do
            local item = item_list[i]

            if item == nil then
                goto continue
            end

            local ref = item.ref

            if ref == nil then
                goto continue
            end

            local value = item_data[ref]

            if value == nil then
                goto continue
            end

            item:set_visible(value)
            item_data[ref] = false

            ::continue::
        end
    end

    local menu_events = menu.get_event_bus() do
        local function on_item_init(item)
            item_data[item.ref] = false
            item:set_visible(false)

            table.insert(item_list, item)
        end

        local function on_item_changed(...)
            logic_events.update:fire(...)
            menu_logic.force_update()
        end

        menu_events.item_init:set(on_item_init)
        menu_events.item_changed:set(on_item_changed)
    end
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

    -- from @enq
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
        local entity_info = c_entity(player)

        if entity_info == nil then
            return
        end

        local anim_state = entity_info:get_anim_state()

        if anim_state == nil then
            return
        end

        local eye_angles_y = anim_state.eye_angles_y
        local goal_feet_yaw = anim_state.goal_feet_yaw

        return utils.normalize(
            eye_angles_y - goal_feet_yaw, -180, 180
        )
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

        local peeking, vulnerable = is_peeking(me)

        local is_onground = bit.band(pre_flags, 1) ~= 0
            and bit.band(post_flags, 1) ~= 0

        local velocity = vector(entity.get_prop(me, 'm_vecVelocity'))
        local duck_amount = entity.get_prop(me, 'm_flDuckAmount')

        local velocity2d_sqr = velocity:length2dsqr()

        localplayer.is_moving = velocity2d_sqr > 5 * 5
        localplayer.is_onground = is_onground

        localplayer.is_peeking = peeking
        localplayer.is_vulnerable = vulnerable

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

    client.set_event_callback('pre_predict_command', on_pre_predict_command)
    client.set_event_callback('predict_command', on_predict_command)
    client.set_event_callback('setup_command', on_setup_command)
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
            teleport = false
        }
    }

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

        local origin = vector(entity.get_origin(me))
        local simtime = toticks(entity.get_prop(me, 'm_flSimulationTime'))

        if old_simtime ~= nil then
            local delta = simtime - old_simtime

            if delta < 0 or delta > 0 and delta <= 64 then
                update_teleport(old_origin, origin)
            end
        end

        data.old_origin = origin
        data.old_simtime = simtime
    end

    local function update_defensive_tick(me)
        local tickbase = entity.get_prop(me, 'm_nTickBase')

        if math.abs(tickbase - max_tickbase) > 64 then
            -- nullify highest tickbase if the difference is too big
            max_tickbase = 0
        end

        local defensive_ticks_left = 0

        -- defensive effect can be achieved because the lag compensation is made so that
        -- it doesn't write records if the current simulation time is less than/equals highest acknowledged simulation time
        -- https://gitlab.com/KittenPopo/csgo-2018-source/-/blame/main/game/server/player_lagcompensation.cpp#L723

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
        local wanted = -15 + (fakelag_limit - 1) + 5 -- error margin

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

    client.set_event_callback('predict_command', on_predict_command)
    client.set_event_callback('setup_command', on_setup_command)
    client.set_event_callback('run_command', on_run_command)

    client.set_event_callback('net_update_start', on_net_update_start)
end

local conditions = { } do
    local list = { }
    local count = 0

    local function add(state)
        count = count + 1
        list[count] = state
    end

    local function clear_list()
        for i = 1, count do
            list[i] = nil
        end

        count = 0
    end

    local function update_onground()
        if not localplayer.is_onground then
            return
        end

        if localplayer.is_moving then
            add 'Moving'

            if localplayer.is_crouched then
                return
            end

            if reference.is_slow_motion() then
                add 'Slow Walk'
            end

            return
        end

        add 'Standing'
    end

    local function update_crouched()
        if not localplayer.is_crouched then
            return
        end

        add 'Crouching'

        if localplayer.is_moving then
            add 'Crouching & Move'
        end
    end

    local function update_in_air()
        if localplayer.is_onground then
            return
        end

        add 'Air'

        if localplayer.is_crouched then
            add 'Air & Crouched'
        end
    end

    function conditions.get()
        return list
    end

    local function on_setup_command()
        clear_list()

        update_onground()
        update_crouched()
        update_in_air()
    end

    client.set_event_callback(
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
        'Manual AA',
        'Legit AA',
    }

    local function new_key(str, key)
        if str:find '\n' == nil then
            str = str .. '\n'
        end

        return str .. key
    end

    local function lock_unselection(item, default_value)
        local old_value = item:get()

        if #old_value == 0 then
            if default_value == nil then
                if item.type == 'multiselect' then
                    default_value = item.list
                elseif item.type == 'list' then
                    default_value = { }

                    for i = 1, #item.list do
                        default_value[i] = i
                    end
                end
            end

            old_value = default_value
            item:set(default_value)
        end

        item:set_callback(function()
            local value = item:get()

            if #value > 0 then
                old_value = value
            else
                item:set(old_value)
            end
        end)
    end

    local function lock_clr()
        return utils.to_hex(75, 75, 75, 255)
    end

    local function def_clr()
        return utils.to_hex(200, 200, 200, 255)
    end

    local category_selector = { } do
        menu_elements.category_selector = category_selector

        category_selector.categories_label = menu.new(
            ui.new_label, 'AA', 'Fake lag', new_key('\n Categories Label', 'category_selector')
        )

        category_selector.categories = menu.new(
            ui.new_combobox, 'AA', 'Fake lag', new_key('\n Categories', 'category_selector'), {'Home', 'Other', 'Anti-Aim'}
        )

        local callbacks do
            local ref_menu_color = ui.reference(
                'Misc', 'Settings', 'Menu color'
            )

            local function get_label_categories()
                local name

                local color_a = color(reference.get_color())

                if category_selector.categories:get() == 'Home' then
                    name = string.format(
                        '\a%s%s\a%s • \a%s%s\a%s • \a%s%s \a%s| %s',
                        reference.get_color(true),
                        '',
                        lock_clr(),
                        def_clr(),
                        '',
                        lock_clr(),
                        def_clr(),
                        '',
                        lock_clr(),
                        text_anims.gradient('Kamibebra', 0.15, 75, 75, 75, 255, color_a.r, color_a.g, color_a.b, color_a.a)
                    )
                end

                if category_selector.categories:get() == 'Other' then
                    name = string.format(
                        '\a%s%s\a%s • \a%s%s\a%s • \a%s%s \a%s| %s',
                        def_clr(),
                        '',
                        lock_clr(),
                        reference.get_color(true),
                        '',
                        lock_clr(),
                        def_clr(),
                        '',
                        lock_clr(),
                        text_anims.gradient('Kamibebra', 0.15, 75, 75, 75, 255, color_a.r, color_a.g, color_a.b, color_a.a)
                    )
                end

                if category_selector.categories:get() == 'Anti-Aim' then
                    name = string.format(
                        '\a%s%s\a%s • \a%s%s\a%s • \a%s%s \a%s| %s',
                        def_clr(),
                        '',
                        lock_clr(),
                        def_clr(),
                        '',
                        lock_clr(),
                        reference.get_color(true),
                        '',
                        lock_clr(),
                        text_anims.gradient('Kamibebra', 0.15, 75, 75, 75, 255, color_a.r, color_a.g, color_a.b, color_a.a)
                    )
                end

                category_selector.categories_label:set(name)
            end

            local function on_menu_color(item)
                get_label_categories()
            end

            category_selector.categories:set_callback(
                get_label_categories
            )

            ui_callback.set(
                ref_menu_color,
                on_menu_color
            )

            get_label_categories()
        end
    end

    local home = { } do
        menu_elements.home = home

        local selector = { } do
            home.selector = selector

            selector.separator = menu.new(
                ui.new_label, 'AA', 'Fake lag', new_key('\n Separator', 'home selector')
            )

            selector.tab_label = menu.new(
                ui.new_label, 'AA', 'Fake lag', new_key('\n Tab Label', 'home selector')
            )

            selector.tab = menu.new(
                ui.new_combobox, 'AA', 'Fake lag', new_key('\n Tab', 'home selector'), {'Local', 'Cloud'}
            )

            selector.separator2 = menu.new(
                ui.new_label, 'AA', 'Fake lag', new_key('\n Separator2', 'home selector')
            )

            local callbacks do
                local ref_menu_color = ui.reference(
                    'Misc', 'Settings', 'Menu color'
                )

                local function get_label_tab()
                    local name

                    if selector.tab:get() == 'Local' then
                        name = string.format(
                            'Type \a%s ~  \a%s%s',
                            lock_clr(),
                            reference.get_color(true),
                            ''
                        )
                    end

                    if selector.tab:get() == 'Cloud' then
                        name = string.format(
                            'Type \a%s ~  \a%s%s',
                            lock_clr(),
                            reference.get_color(true),
                            ''
                        )
                    end

                    selector.tab_label:set(name)
                end

                local function on_menu_color(item)
                    get_label_tab()
                end

                selector.tab:set_callback(
                    get_label_tab
                )


                ui_callback.set(
                    ref_menu_color,
                    on_menu_color
                )

                get_label_tab()
            end
        end

        local bred_ebaniy = { } do
            home.bred_ebaniy = bred_ebaniy

            local function discord_server_link()
                local link = 'https://discord.gg/sosal'
                panorama.open().SteamOverlayAPI.OpenExternalBrowserURL(link)
            end

            local function youtube1_link()
                local link = 'https://youtube.com/u/sosal'
                panorama.open().SteamOverlayAPI.OpenExternalBrowserURL(link)
            end

            local function youtube2_link()
                local link = 'https://youtube.com/u/sosal2'
                panorama.open().SteamOverlayAPI.OpenExternalBrowserURL(link)
            end

            local wrapper_slider_label = theme_controller.wrap(new_key(string.format('Socials  \a%s~  ${%s}', lock_clr(), ''), 'config_local'))

            bred_ebaniy.slider_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_slider_label()
            )

            theme_controller.push(bred_ebaniy.slider_label, wrapper_slider_label)

            bred_ebaniy.slider = menu.new(
                ui.new_slider, 'AA', 'Anti-aimbot angles', '\n Slider ebat', 0, 2, 1, true, '', 0, {
                    [0] = string.format('\a%s \a%sDiscord', lock_clr(), def_clr()),
                    [1] = string.format('\a%s \a%sMephissa', lock_clr(), def_clr()),
                    [2] = string.format('\a%s \a%sMeow', lock_clr(), def_clr())
                }
            )

            bred_ebaniy.discord_server = menu.new(
                ui.new_button, 'AA', 'Anti-aimbot angles', string.format('Our discord server  \a%s~  \a%s%s', lock_clr(), def_clr(), ''), discord_server_link
            )

            bred_ebaniy.youtube_1 = menu.new(
                ui.new_button, 'AA', 'Anti-aimbot angles', string.format('Youtube  \a%s~  \a%s%s', lock_clr(), def_clr(), ''), youtube1_link
            )

            bred_ebaniy.youtube_2 = menu.new(
                ui.new_button, 'AA', 'Anti-aimbot angles', string.format('Youtube  \a%s~  \a%s%s', lock_clr(), def_clr(), ''), youtube2_link
            )

            bred_ebaniy.separator = menu.new(
                ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator bred_ebaniy', 'config_local')
            )
        end

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
                        '\a%s%s \a%s~  \a%sWelcome to our club \a%s| \a%s%s',
                        reference.get_color(true),
                        '',
                        lock_clr(),
                        def_clr(),
                        lock_clr(),
                        reference.get_color(true),
                        script.user
                ), 'config_local'))

                welcome.user = menu.new(
                        ui.new_label, 'AA', 'Fake lag', wrapper_user_label()
                )

                theme_controller.push(welcome.user, wrapper_user_label)

                local wrapper_build_label = theme_controller.wrap(new_key(string.format(
                        '\a%s%s \a%s~  \a%sYour build \a%s| \a%s%s',
                        reference.get_color(true),
                        '',
                        lock_clr(),
                        def_clr(),
                        lock_clr(),
                        reference.get_color(true),
                        script.build
                ), 'config_local'))

                welcome.build = menu.new(
                        ui.new_label, 'AA', 'Fake lag', wrapper_build_label()
                )

                theme_controller.push(welcome.build, wrapper_build_label)

                end


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
                ui.new_textbox, 'AA', 'Other', new_key('\n Input', 'config_local')
            )

            config_local.load = menu.new(
                ui.new_button, 'AA', 'Other', string.format('Load  \a%s~  \a%s%s', lock_clr(), def_clr(), ''), DUMMY
            )

            config_local.save = menu.new(
                ui.new_button, 'AA', 'Other', string.format('Save  \a%s~  \a%s%s', lock_clr(), def_clr(), ''), DUMMY
            )

            config_local.import = menu.new(
                ui.new_button, 'AA', 'Other', string.format('Import  \a%s~  \a%s%s', lock_clr(), def_clr(), ''), DUMMY
            )

            config_local.export = menu.new(
                ui.new_button, 'AA', 'Other', string.format('Export  \a%s~  \a%s%s', lock_clr(), def_clr(), ''), DUMMY
            )

            config_local.delete = menu.new(
                ui.new_button, 'AA', 'Other', string.format('Delete  \a%s~  \a%s%s', lock_clr(), 'FF173CFF', ''), DUMMY
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

        local configs_cloud = { } do
            home.configs_cloud = configs_cloud

            --ты думал тут что-то будет ? ??????
        end
    end

    local other = { } do
        menu_elements.other = other

        local selector = { } do
            other.selector = selector

            selector.separator = menu.new(
                ui.new_label, 'AA', 'Fake lag', new_key('\n Separator', 'other selector')
            )

            selector.tab_label = menu.new(
                ui.new_label, 'AA', 'Fake lag', new_key('\n Tab Label', 'other selector')
            )

            selector.tab = menu.new(
                ui.new_combobox, 'AA', 'Fake lag', new_key('\n Tab', 'other selector'), {'Ragebot', 'Visuals', 'Miscellaneous'}
            )

            selector.separator2 = menu.new(
                ui.new_label, 'AA', 'Fake lag', new_key('\n Separator2', 'other selector')
            )

            local callbacks do
                local ref_menu_color = ui.reference(
                    'Misc', 'Settings', 'Menu color'
                )

                local function get_label_tab()
                    local name

                    if selector.tab:get() == 'Ragebot' then
                        name = string.format(
                            'Type \a%s ~  \a%s%s',
                            lock_clr(),
                            reference.get_color(true),
                            ''
                        )
                    end

                    if selector.tab:get() == 'Visuals' then
                        name = string.format(
                            'Type \a%s ~  \a%s%s',
                            lock_clr(),
                            reference.get_color(true),
                            ''
                        )
                    end

                    if selector.tab:get() == 'Miscellaneous' then
                        name = string.format(
                            'Type \a%s ~  \a%s%s',
                            lock_clr(),
                            reference.get_color(true),
                            ''
                        )
                    end

                    selector.tab_label:set(name)
                end

                local function on_menu_color(item)
                    get_label_tab()
                end

                selector.tab:set_callback(
                    get_label_tab
                )

                ui_callback.set(
                    ref_menu_color,
                    on_menu_color
                )

                get_label_tab()
            end
        end

        local rage = { } do
            other.rage = rage

            rage.pitch_correction = config_system.push(
                'Rage', 'pitch_correction.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Fake Lag', new_key('Pitch Correction', 'pitch_correction')
                )
            )

            local automatic_peek = { } do
                rage.automatic_peek = automatic_peek

                automatic_peek.checkbox = config_system.push(
                    'Rage', 'automatic_peek.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Fake Lag', new_key('Automatic peek', 'automatic_peek')
                    )
                )

                automatic_peek.hotkey = config_system.push(
                    'Rage', 'automatic_peek.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Fake Lag', new_key('Hotkey', 'automatic_peek'), true
                    )
                )

                automatic_peek.type = config_system.push(
                    'Rage', 'automatic_peek.range', menu.new(
                        ui.new_combobox, 'AA', 'Fake Lag', new_key('\n Type', 'automatic_peek'), {'Offensive', 'Defensive'}
                    )
                )

                local wrapper_options_label = theme_controller.wrap(new_key(string.format('Options  ${~}'), 'automatic_peek'))

                automatic_peek.options_label = menu.new(
                    ui.new_label, 'AA', 'Fake Lag', wrapper_options_label()
                )

                theme_controller.push(automatic_peek.options_label, wrapper_options_label)

                automatic_peek.options = config_system.push(
                    'Rage', 'automatic_peek.options', menu.new(
                        ui.new_multiselect, 'AA', 'Fake Lag', new_key('\n Options', 'automatic_peek'),  {'Visualize'}
                    )
                )

                automatic_peek.color = config_system.push(
                    'Rage', 'automatic_peek.color', menu.new(
                        ui.new_color_picker, 'AA', 'Fake Lag', new_key('\n Color', 'automatic_peek')
                    )
                )
            end

            local air_auto_stop = { } do
                rage.air_auto_stop = air_auto_stop

                air_auto_stop.checkbox = config_system.push(
                    'Rage', 'air_auto_stop.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Air auto stop', 'air_auto_stop')
                    )
                )

                air_auto_stop.addons = config_system.push(
                    'Rage', 'air_auto_stop.addons', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Addons', 'air_auto_stop'), {'Only if quick peek assist', 'Work if speed lower than X'}
                    )
                )

                local wrapper_hitchance_label = theme_controller.wrap(new_key('Hitchance ${•}', 'air_auto_stop'))

                air_auto_stop.hitchance_label = menu.new(
                   ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_hitchance_label()
                )

                theme_controller.push(air_auto_stop.hitchance_label, wrapper_hitchance_label)

                air_auto_stop.hitchance = config_system.push(
                    'Rage', 'air_auto_stop.hitchance', menu.new(
                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Hitchance', 'air_auto_stop'), 0, 100, 50, true, '%', 1
                    )
                )
                local wrapper_distance_label = theme_controller.wrap(new_key('Distance ${•}', 'air_auto_stop'))

                air_auto_stop.distance_label = menu.new(
                   ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_distance_label()
                )

                theme_controller.push(air_auto_stop.distance_label, wrapper_distance_label)

                air_auto_stop.distance = config_system.push(
                    'Rage', 'air_auto_stop.distance', menu.new(
                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Distance', 'air_auto_stop'), 50, 400, 200, true, 'u', 1
                    )
                )

                local wrapper_speed_label = theme_controller.wrap(new_key('Speed ${•}', 'air_auto_stop'))

                air_auto_stop.speed_label = menu.new(
                   ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_speed_label()
                )

                theme_controller.push(air_auto_stop.speed_label, wrapper_speed_label)

                air_auto_stop.speed = config_system.push(
                    'Rage', 'air_auto_stop.speed', menu.new(
                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Speed', 'air_auto_stop'), 10, 450, 270, true, 'u'
                    )
                )

                air_auto_stop.separator = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'air_auto_stop')
                )
            end

            local auto_osaa = { } do
                rage.auto_osaa = auto_osaa

                local weapon_list = {
                    'Auto Snipers',
                    'Desert Eagle',
                    'Revolver R8',
                    'Pistols',
                    'Scout',
                    'AWP'
                }

                local state_list = {
                    [1] = 'Standing',
                    [2] = 'Moving',
                    [3] = 'Slow Walk',
                    [4] = 'Crouching',
                    [5] = 'Crouching & Move',
                    [6] = 'Air',
                    [7] = 'Air & Crouched'
                }

                auto_osaa.checkbox = config_system.push(
                    'Rage', 'auto_osaa.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('\aB6B665FFAuto On shot anti-aim', 'auto_osaa')
                    )
                )

                auto_osaa.weapon = config_system.push(
                    'Rage', 'auto_osaa.weapon', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Weapon', 'auto_osaa'), weapon_list
                    )
                )

                lock_unselection(auto_osaa.weapon)

                local wrapper_state_label = theme_controller.wrap(new_key(string.format('State  ${~}'),'auto_osaa'))

                auto_osaa.state_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_state_label()
                )

                theme_controller.push(auto_osaa.state_label, wrapper_state_label)

                auto_osaa.state = config_system.push(
                    'Rage', 'auto_osaa.state', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n State', 'auto_osaa'), state_list
                    )
                )

                lock_unselection(auto_osaa.state, {
                    'Slow Walk',
                    'Crouching',
                    'Crouching & Move'
                })

                auto_osaa.separator = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'auto_osaa')
                )
            end

            local auto_discharge = { } do
                rage.auto_discharge = auto_discharge

                auto_discharge.checkbox = config_system.push(
                    'Rage', 'auto_discharge.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('\aB6B665FFAuto exploit discharge', 'auto_discharge')
                    )
                )

                auto_discharge.hotkey = config_system.push(
                    'Rage', 'auto_discharge.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Hotkey', 'auto_discharge'), true
                    )
                )

                auto_discharge.mode = config_system.push(
                    'Rage', 'auto_discharge.mode', menu.new(
                        ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Mode', 'auto_discharge'), {'Default', 'Air lag'}
                    )
                )

                local wrapper_tick_label = theme_controller.wrap(new_key('Delay ${•}', 'auto_discharge'))

                auto_discharge.tick_label = menu.new(
                   ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_tick_label()
                )

                theme_controller.push(auto_discharge.tick_label, wrapper_tick_label)

                auto_discharge.tick = config_system.push(
                    'Rage', 'auto_discharge.tick', menu.new(
                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Tick', 'auto_discharge'), 0, 16, 1, true, 't', 1
                    )
                )

                auto_discharge.separator = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'auto_discharge')
                )
            end

            rage.unsafe_exploit = config_system.push(
                'Rage', 'unsafe_exploit.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Unsafe exploit recharge', 'unsafe_exploit')
                )
            )

            rage.disable_hold_tick = config_system.push(
                'Rage', 'disable_hold_tick.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Disable Hold Ticks', 'disable_hold_tick')
                )
            )

            local predict_enemies = { } do
                rage.predict_enemies = predict_enemies

                predict_enemies.checkbox = config_system.push(
                    'Rage', 'predict_enemies.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('Predict enemies', 'predict_enemies')
                    )
                )

                predict_enemies.hotkey = config_system.push(
                    'Rage', 'predict_enemies.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Other', new_key('Hotkey', 'predict_enemies'), true
                    )
                )
            end

            local hitchance = { } do
                rage.hitchance = hitchance


                local option_list = {
                    'In Air',
                    'No Scope',
                    'Hotkey'
                }

                local weapon_list = {
                    'Auto Snipers',
                    'Desert Eagle',
                    'R8 Revolver',
                    'Pistols',
                    'Scout',
                    'AWP'
                }

                hitchance.checkbox = config_system.push(
                    'Rage', 'hitchance.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('Hitchance override', 'hitchance')
                    )
                )

                hitchance.weapon = menu.new(
                    ui.new_combobox, 'AA', 'Other', new_key('\n Weapon', 'hitchance'), weapon_list
                )

                for i = 1, #weapon_list do
                    local weapon = weapon_list[i]

                    local should_has_scope = (
                        weapon == 'Auto Snipers' or
                        weapon == 'Scout' or
                        weapon == 'AWP'
                    )

                    local new_option_list = {
                        unpack(option_list)
                    }

                    if not should_has_scope then
                        local index = contains(
                            new_option_list, 'No Scope'
                        )

                        if index ~= nil then
                            table.remove(new_option_list, index)
                        end
                    end

                    local function hash(name)
                        return string.format(
                            'hitchance.%s[%s]',
                            name, weapon
                        )
                    end

                    local items = { }

                    local wrapper_options_label = theme_controller.wrap(new_key(string.format('Options  ${~}'), hash 'options'))

                    items.options_label = menu.new(
                            ui.new_label, 'AA', 'Other', wrapper_options_label()
                    )

                    theme_controller.push(items.options_label, wrapper_options_label)

                    items.options = config_system.push(
                        'Rage', hash 'options', menu.new(
                            ui.new_multiselect, 'AA', 'Other', new_key('\n Options', hash 'options'), new_option_list
                        )
                    )

                    for j = 1, #new_option_list do
                        local option = new_option_list[j]

                        local function hash_option(name)
                            return hash(string.format(
                                '%s[%s]', option, name
                            ))
                        end

                        local option_items = { }

                        local wrapper_value_label = theme_controller.wrap(new_key(string.format('%s ${•}', option), hash_option 'value'))

                        option_items.value_label = menu.new(
                                ui.new_label, 'AA', 'Other', wrapper_value_label()
                        )

                        theme_controller.push(option_items.value_label, wrapper_value_label)


                        option_items.value = config_system.push(
                            'Rage', hash_option 'value', menu.new(
                                ui.new_slider, 'AA', 'Other', new_key(string.format('\n %s', option), hash_option 'value'), 0, 100, 0, true, '%'
                            )
                        )

                        if option == 'No Scope' then
                            local wrapper_distance_label = theme_controller.wrap(new_key('Distance ${•}', hash_option 'distance'))

                            option_items.distance_label = menu.new(
                                ui.new_label, 'AA', 'Other', wrapper_distance_label()
                            )

                            theme_controller.push(option_items.distance_label, wrapper_distance_label)

                            option_items.distance = config_system.push(
                                'Rage', hash_option 'distance', menu.new(
                                    ui.new_slider, 'AA', 'Other', new_key('\n Distance', hash_option 'distance'), 5, 101, 35, true, 'u', 1, {
                                        [101] = 'Inf'
                                    }
                                )
                            )
                        end

                        items[option] = option_items
                    end

                    hitchance[weapon] = items
                end

                hitchance.hotkey = config_system.push(
                    'Rage', 'hitchance.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Other', 'Override hitchance', true
                    )
                )

                hitchance.option_list = option_list
            end

            local aimbot_helper = { } do
                rage.aimbot_helper = aimbot_helper

                local weapon_list = {
                    'Auto Snipers',
                    'Scout',
                    'AWP',
                    'R8 Revolver',
                    'Desert Eagle',
                    'Pistols',
                    'Rifle',
                    'Shotgun',
                    'SMG',
                    'Machine gun'
                }

                local trigger_list = {
                    'Enemy HP < X',
                    'X missed shots',
                    'Lethal',
                    'Height advantage',
                    'Enemy higher than you'
                }

                aimbot_helper.checkbox = config_system.push(
                    'Rage', 'aimbot_helper.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Aimbot helper', 'aimbot_helper')
                    )
                )

                aimbot_helper.weapons = menu.new(
                    ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n weapon', 'aimbot_helper'), weapon_list
                )

                for i = 1, #weapon_list do
                    local weapon = weapon_list[i]

                    local function hash_weapon(name)
                        return string.format(
                            'aimbot_helper.%s[%s]',
                            name, weapon
                        )
                    end

                    local items = { }

                    local wrapper_options_label = theme_controller.wrap(new_key(string.format('Options  ${~}'), hash_weapon 'options'))

                    items.options_label = menu.new(
                            ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_options_label()
                    )

                    theme_controller.push(items.options_label, wrapper_options_label)

                    items.options = config_system.push(
                        'Rage', hash_weapon 'options', menu.new(
                            ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Options', hash_weapon 'options'), {
                                'Force safe point',
                                'Prefer body aim',
                                'Force body aim',
                                'Ping spike'
                            }
                        )
                    )

                    local force_safe_point = { } do
                        local wrapper_triggers_label = theme_controller.wrap(new_key(string.format('Force safe point  ${~}'), hash_weapon 'force_safe_point'))

                        force_safe_point.triggers_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_triggers_label()
                        )

                        theme_controller.push(force_safe_point.triggers_label, wrapper_triggers_label)

                        force_safe_point.triggers = config_system.push(
                            'Rage', hash_weapon 'force_safe_point', menu.new(
                                ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Force safe point', hash_weapon 'force_safe_point'), trigger_list
                            )
                        )

                        local wrapper_hp_label = theme_controller.wrap(new_key('Hp ${•}', hash_weapon 'force_safe_point.hp'))

                        force_safe_point.hp_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_hp_label()
                        )

                        theme_controller.push(force_safe_point.hp_label, wrapper_hp_label)

                        force_safe_point.hp = config_system.push(
                            'Rage', hash_weapon 'force_safe_point.hp', menu.new(
                                ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n HP', hash_weapon 'force_safe_point.hp'), 1, 100, 0, true
                            )
                        )

                        local wrapper_missed_shots_label = theme_controller.wrap(new_key('Missed shots ${•}', hash_weapon 'force_safe_point.missed_shots'))

                        force_safe_point.missed_shots_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_missed_shots_label()
                        )

                        theme_controller.push(force_safe_point.missed_shots_label, wrapper_missed_shots_label)

                        force_safe_point.missed_shots = config_system.push(
                            'Rage', hash_weapon 'force_safe_point.missed_shots', menu.new(
                                ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Missed shots', hash_weapon 'force_safe_point.missed_shots'), 1, 10, 0, true
                            )
                        )

                        items.force_safe_point = force_safe_point
                    end

                    local prefer_body_aim = { } do
                        local wrapper_triggers_label = theme_controller.wrap(new_key(string.format('Prefer body aim  ${~}'), hash_weapon 'prefer_body_aim'))

                        prefer_body_aim.triggers_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_triggers_label()
                        )

                        theme_controller.push(prefer_body_aim.triggers_label, wrapper_triggers_label)

                        prefer_body_aim.triggers = config_system.push(
                            'Rage', hash_weapon 'prefer_body_aim', menu.new(
                                ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Prefer body aim', hash_weapon 'prefer_body_aim'), trigger_list
                            )
                        )

                        local wrapper_hp_label = theme_controller.wrap(new_key('Hp ${•}', hash_weapon 'prefer_body_aim.hp'))

                        prefer_body_aim.hp_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_hp_label()
                        )

                        theme_controller.push(prefer_body_aim.hp_label, wrapper_hp_label)

                        prefer_body_aim.hp = config_system.push(
                            'Rage', hash_weapon 'prefer_body_aim.hp', menu.new(
                                ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n HP', hash_weapon 'prefer_body_aim.hp'), 1, 100, 0, true
                            )
                        )

                        local wrapper_missed_shots_label = theme_controller.wrap(new_key('Missed shots ${•}', hash_weapon 'prefer_body_aim.missed_shots'))

                        prefer_body_aim.missed_shots_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_missed_shots_label()
                        )

                        theme_controller.push(prefer_body_aim.missed_shots_label, wrapper_missed_shots_label)

                        prefer_body_aim.missed_shots = config_system.push(
                            'Rage', hash_weapon 'prefer_body_aim.missed_shots', menu.new(
                                ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Missed shots', hash_weapon 'prefer_body_aim.missed_shots'), 1, 10, 0, true
                            )
                        )

                        items.prefer_body_aim = prefer_body_aim
                    end

                    local force_body_aim = { } do
                        local wrapper_triggers_label = theme_controller.wrap(new_key(string.format('Force body aim  ${~}'), hash_weapon 'force_body_aim'))

                        force_body_aim.triggers_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_triggers_label()
                        )

                        theme_controller.push(force_body_aim.triggers_label, wrapper_triggers_label)

                        force_body_aim.triggers = config_system.push(
                            'Rage', hash_weapon 'force_body_aim', menu.new(
                                ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Force body aim', hash_weapon 'force_body_aim'), trigger_list
                            )
                        )

                        local wrapper_hp_label = theme_controller.wrap(new_key('Hp ${•}', hash_weapon 'force_body_aim.hp'))

                        force_body_aim.hp_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_hp_label()
                        )

                        theme_controller.push(force_body_aim.hp_label, wrapper_hp_label)

                        force_body_aim.hp = config_system.push(
                            'Rage', hash_weapon 'force_body_aim.hp', menu.new(
                                ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n HP', hash_weapon 'force_body_aim.hp'), 1, 100, 0, true
                            )
                        )

                        local wrapper_missed_shots_label = theme_controller.wrap(new_key('Missed shots ${•}', hash_weapon 'force_body_aim.missed_shots'))

                        force_body_aim.missed_shots_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_missed_shots_label()
                        )

                        theme_controller.push(force_body_aim.missed_shots_label, wrapper_missed_shots_label)

                        force_body_aim.missed_shots = config_system.push(
                            'Rage', hash_weapon 'force_body_aim.missed_shots', menu.new(
                                ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Missed shots', hash_weapon 'force_body_aim.missed_shots'), 1, 10, 0, true
                            )
                        )

                        items.force_body_aim = force_body_aim
                    end

                    local ping_spike = { } do
                        local wrapper_value_label = theme_controller.wrap(new_key('Ping spike ${•}', hash_weapon 'ping_spike'))

                        ping_spike.value_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_value_label()
                        )

                        theme_controller.push(ping_spike.value_label, wrapper_value_label)

                        ping_spike.value = config_system.push(
                            'Rage', hash_weapon 'ping_spike', menu.new(
                                ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Ping spike', hash_weapon 'ping_spike'), 1, 200, 0, true, 'ms'
                            )
                        )

                        items.ping_spike = ping_spike
                    end

                    aimbot_helper[weapon] = items
                end
            end

            local callbacks do
                local ref_menu_color = ui.reference(
                    'Misc', 'Settings', 'Menu color'
                )

                local function on_menu_color(item)
                    -- general.script_name:set(get_script_name_label())
                end

                ui_callback.set(
                    ref_menu_color,
                    get_label_tab
                )


                ui_callback.set(
                    ref_menu_color,
                    on_menu_color
                )
            end
        end

        local visual = { } do
            other.visual = visual

            local viewmodel = { } do
                visual.viewmodel = viewmodel

                viewmodel.checkbox = config_system.push(
                    'Miscellaneous', 'viewmodel.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Viewmodel', 'viewmodel')
                    )
                )

                viewmodel.fov = config_system.push(
                    'Miscellaneous', 'viewmodel.fov', menu.new(
                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('Field of fov', 'viewmodel'), 0, 1000, 680, true, '°', 0.1
                    )
                )

                viewmodel.offset_x = config_system.push(
                    'Miscellaneous', 'viewmodel.offset_x', menu.new(
                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('Offset X', 'viewmodel'), -100, 100, 0, true, '', 0.1
                    )
                )

                viewmodel.offset_y = config_system.push(
                    'Miscellaneous', 'viewmodel.offset_y', menu.new(
                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('Offset Y', 'viewmodel'), -100, 100, 0, true, '', 0.1
                    )
                )

                viewmodel.offset_z = config_system.push(
                    'Miscellaneous', 'viewmodel.offset_z', menu.new(
                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('Offset Z', 'viewmodel'), -100, 100, 0, true, '', 0.1
                    )
                )

                viewmodel.options = config_system.push(
                    'Miscellaneous', 'viewmodel.options', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Opposite knife hand', 'viewmodel')
                    )
                )
            end

        end

        local miscellaneous = { } do
            other.miscellaneous = miscellaneous


            miscellaneous.console_filter = config_system.push(
                'Miscellaneous', 'console_filter.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Fake Lag', new_key('Console filter', 'console_filter')
                )
            )

            miscellaneous.item_crash_fix = config_system.push(
                'Miscellaneous', 'item_crash_fix.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Fake Lag', new_key('Item crash fix', 'item_crash_fix')
                )
            )

            miscellaneous.allow_duck_on_fd = config_system.push(
                'Miscellaneous', 'allow_duck_on_fd.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Fake Lag', new_key('Allow duck on fd', 'allow_duck_on_fd')
                )
            )

            miscellaneous.clantag = config_system.push(
                'Miscellaneous', 'clantag.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Fake Lag', new_key('Clan tag spammer', 'clantag')
                )
            )

            miscellaneous.enemy_chat_viewer = config_system.push(
                'Miscellaneous', 'enemy_chat_viewer.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Fake Lag', new_key('Reveal enemy teamchat', 'enemy_chat_viewer')
                )
            )

            miscellaneous.fast_ladder = config_system.push(
                'Miscellaneous', 'fast_ladder.checkbox', menu.new(
                    ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Fast Ladder', 'fast_ladder')
                )
            )
            local drop_nades = { } do
                miscellaneous.drop_nades = drop_nades

                drop_nades.checkbox = config_system.push(
                    'Miscellaneous', 'drop_nades.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Drop nades', 'drop_nades')
                    )
                )

                drop_nades.hotkey = config_system.push(
                    'Miscellaneous', 'drop_nades.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Hotkey', 'drop_nades'), true
                    )
                )

                local wrapper_grenades_label = theme_controller.wrap(new_key(string.format('Grenades  ${~}'), 'drop_nades'))

                drop_nades.grenades_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_grenades_label()
                )

                theme_controller.push(drop_nades.grenades_label, wrapper_grenades_label)

                drop_nades.grenades = config_system.push(
                    'Miscellaneous', 'drop_nades.grenades', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Grenades', 'drop_nades'), {
                            'HE Grenade',
                            'Molotov',
                            'Smoke'
                        }
                    )
                )

                drop_nades.separator = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'drop_nades')
                )
            end

            local edge_quick_stop = { } do
                miscellaneous.edge_quick_stop = edge_quick_stop

                edge_quick_stop.checkbox = config_system.push(
                    'Miscellaneous', 'edge_quick_stop.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Edge quick stop', 'edge_quick_stop')
                    )
                )

                edge_quick_stop.hotkey = config_system.push(
                    'Miscellaneous', 'edge_quick_stop.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Hotkey', 'edge_quick_stop'), true
                    )
                )
            end

            local trash_talk = { } do
                miscellaneous.trash_talk = trash_talk

                trash_talk.checkbox = config_system.push(
                    'Miscellaneous', 'trash_talk.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Trash talk', 'trash_talk')
                    )
                )

                trash_talk.type = config_system.push(
                    'Miscellaneous', 'trash_talk.type', menu.new(
                        ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Type', 'trash_talk'), {
                            'Kamibebra',
                            'Bait'
                        }
                    )
                )

                local wrapper_events_label = theme_controller.wrap(new_key(string.format('Events  ${~}'), 'trash_talk'))

                trash_talk.events_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_events_label()
                )

                theme_controller.push(trash_talk.events_label, wrapper_events_label)

                trash_talk.events = config_system.push(
                    'Miscellaneous', 'trash_talk.events', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Events', 'trash_talk'), {
                            'On kill',
                            'On death'
                        }
                    )
                )
            end

            local game_enhancer = { } do
                miscellaneous.game_enhancer = game_enhancer

                game_enhancer.checkbox = config_system.push(
                    'Miscellaneous', 'game_enhancer.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Game enhancer', 'game_enhancer')
                    )
                )

                game_enhancer.list = config_system.push(
                    'Miscellaneous', 'game_enhancer.list', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n List', 'game_enhancer'), {
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
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'game_enhancer')
                )
            end

            local animations = { } do
                miscellaneous.animations = animations

                animations.checkbox = config_system.push(
                    'Miscellaneous', 'animations.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Animations', 'animations')
                    )
                )

                animations.conditions = config_system.push(
                    'Miscellaneous', 'animations.conditions', menu.new(
                        ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Conditions', 'animations'), {
                            'Moving',
                            'In Air'
                        }
                    )
                )

                local moving = { } do
                    animations.moving = moving

                    local wrapper_type_label = theme_controller.wrap(new_key('Type ${»}', 'moving_type'))

                    moving.type_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_type_label()
                    )

                    theme_controller.push(moving.type_label, wrapper_type_label)

                    moving.type = config_system.push(
                        'Miscellaneous', 'animations.moving_type', menu.new(
                            ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Type', 'moving_type'), {
                                'Off',
                                'Static',
                                'Jitter',
                                'Alternative Jitter',
                                'Allah'
                            }
                        )
                    )

                    local wrapper_min_jitter_label = theme_controller.wrap(new_key('Minimum Jitter Percent ${•}', 'moving_type'))

                    moving.min_jitter_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_min_jitter_label()
                    )

                    theme_controller.push(moving.min_jitter_label, wrapper_min_jitter_label)

                    moving.min_jitter = config_system.push(
                        'Rage', 'animations.moving_min_jitter', menu.new(
                            ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Minimum Jitter Percent', 'moving_type'), 0, 100, 0, true, '%'
                        )
                    )

                    local wrapper_max_jitter_label = theme_controller.wrap(new_key('Maximum Jitter Percent ${•}', 'moving_type'))

                    moving.max_jitter_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_max_jitter_label()
                    )

                    theme_controller.push(moving.max_jitter_label, wrapper_max_jitter_label)

                    moving.max_jitter = config_system.push(
                        'Rage', 'animations.moving_max_jitter', menu.new(
                            ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Maximum Jitter Percent', 'moving_type'), 0, 100, 100, true, '%'
                        )
                    )

                    local wrapper_options_label = theme_controller.wrap(new_key('Options  ${~}', 'moving_type'))

                    moving.options_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_options_label()
                    )

                    theme_controller.push(moving.options_label, wrapper_options_label)

                    moving.options = config_system.push(
                        'Miscellaneous', 'animations.moving_options', menu.new(
                            ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Options', 'moving_type'), {
                                'Body Lean',
                            }
                        )
                    )

                    local wrapper_body_lean_label = theme_controller.wrap(new_key('Leaning Percent ${•}', 'moving_type'))

                    moving.body_lean_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_lean_label()
                    )

                    theme_controller.push(moving.body_lean_label, wrapper_body_lean_label)

                    moving.body_lean = config_system.push(
                        'Rage', 'animations.moving_body_lean', menu.new(
                            ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Leaning Percent', 'moving_type'), 0, 100, 70, true, '%'
                        )
                    )
                end

                local air = { } do
                    animations.air = air

                    local wrapper_type_label = theme_controller.wrap(new_key('Type ${»}', 'air_type'))

                    air.type_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_type_label()
                    )

                    theme_controller.push(air.type_label, wrapper_type_label)

                    air.type = config_system.push(
                        'Miscellaneous', 'animations.air_type', menu.new(
                            ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Type', 'air_type'), {
                                'Off',
                                'Static',
                                'Jitter',
                                'Allah'
                            }
                        )
                    )

                    local wrapper_min_jitter_label = theme_controller.wrap(new_key('Minimum Jitter Percent ${•}', 'air_type'))

                    air.min_jitter_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_min_jitter_label()
                    )

                    theme_controller.push(air.min_jitter_label, wrapper_min_jitter_label)

                    air.min_jitter = config_system.push(
                        'Rage', 'animations.air_min_jitter', menu.new(
                            ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Minimum Jitter Percent', 'air_type'), 0, 100, 0, true, '%'
                        )
                    )

                    local wrapper_max_jitter_label = theme_controller.wrap(new_key('Maximum Jitter Percent ${•}', 'air_type'))

                    air.max_jitter_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_max_jitter_label()
                    )

                    theme_controller.push(air.max_jitter_label, wrapper_max_jitter_label)

                    air.max_jitter = config_system.push(
                        'Rage', 'animations.air_max_jitter', menu.new(
                            ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Maximum Jitter Percent', 'air_type'), 0, 100, 100, true, '%'
                        )
                    )

                    local wrapper_options_label = theme_controller.wrap(new_key('Options  ${~}', 'air_type'))

                    air.options_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_options_label()
                    )

                    theme_controller.push(air.options_label, wrapper_options_label)

                    air.options = config_system.push(
                        'Miscellaneous', 'animations.air_options', menu.new(
                            ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Options', 'air_type'), {
                                'Body Lean',
                                'Zero Pitch On Landing'
                            }
                        )
                    )

                    local wrapper_body_lean_label = theme_controller.wrap(new_key('Leaning Percent ${•}', 'air_type'))

                    air.body_lean_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_lean_label()
                    )

                    theme_controller.push(air.body_lean_label, wrapper_body_lean_label)

                    air.body_lean = config_system.push(
                        'Rage', 'animations.air_body_lean', menu.new(
                            ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Leaning Percent', 'air_type'), 0, 100, 70, true, '%'
                        )
                    )
                end
            end

            local automatic_purchase = { } do
                miscellaneous.automatic_purchase = automatic_purchase

                automatic_purchase.checkbox = config_system.push(
                    'Miscellaneous', 'automatic_purchase.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('Automatic purchase', 'automatic_purchase')
                    )
                )

                automatic_purchase.primary = config_system.push(
                    'Miscellaneous', 'automatic_purchase.primary', menu.new(
                        ui.new_combobox, 'AA', 'Other', new_key('\n Primary', 'automatic_purchase'), {
                            'Off',
                            'AWP',
                            'Scout',
                            'G3SG1 / SCAR-20'
                        }
                    )
                )

                local wrapper_alternative_label = theme_controller.wrap(new_key(string.format('Alternative ${»}'), 'automatic_purchase'))

                automatic_purchase.alternative_label = menu.new(
                        ui.new_label, 'AA', 'Other', wrapper_alternative_label()
                )

                theme_controller.push(automatic_purchase.alternative_label, wrapper_alternative_label)

                automatic_purchase.alternative = config_system.push(
                    'Miscellaneous', 'automatic_purchase.alternative', menu.new(
                        ui.new_combobox, 'AA', 'Other', new_key('\n Alternative', 'automatic_purchase'), {
                            'Off',
                            'Scout',
                            'G3SG1 / SCAR-20'
                        }
                    )
                )

                local wrapper_secondary_label = theme_controller.wrap(new_key(string.format('Secondary ${»}'), 'automatic_purchase'))

                automatic_purchase.secondary_label = menu.new(
                        ui.new_label, 'AA', 'Other', wrapper_secondary_label()
                )

                theme_controller.push(automatic_purchase.secondary_label, wrapper_secondary_label)

                automatic_purchase.secondary = config_system.push(
                    'Miscellaneous', 'automatic_purchase.secondary', menu.new(
                        ui.new_combobox, 'AA', 'Other', new_key('\n Secondary', 'automatic_purchase'), {
                            'Off',
                            'P250',
                            'Elites',
                            'Five-seven / Tec-9 / CZ75',
                            'Deagle / R8 Revolver'
                        }
                    )
                )

                local wrapper_equipment_label = theme_controller.wrap(new_key(string.format('Equipment  ${~}'), 'automatic_purchase'))

                automatic_purchase.equipment_label = menu.new(
                        ui.new_label, 'AA', 'Other', wrapper_equipment_label()
                )

                theme_controller.push(automatic_purchase.equipment_label, wrapper_equipment_label)

                automatic_purchase.equipment = config_system.push(
                    'Miscellaneous', 'automatic_purchase.equipment', menu.new(
                        ui.new_multiselect, 'AA', 'Other', new_key('\n Equipment', 'automatic_purchase'), {
                            'Kevlar',
                            'Kevlar + Helmet',
                            'Defuse kit',
                            'HE',
                            'Smoke',
                            'Molotov',
                            'Taser'
                        }
                    )
                )

                local wrapper_options_label = theme_controller.wrap(new_key(string.format('Options  ${~}'), 'automatic_purchase'))

                automatic_purchase.options_label = menu.new(
                        ui.new_label, 'AA', 'Other', wrapper_options_label()
                )

                theme_controller.push(automatic_purchase.options_label, wrapper_options_label)

                automatic_purchase.options = config_system.push(
                    'Miscellaneous', 'automatic_purchase.options', menu.new(
                        ui.new_multiselect, 'AA', 'Other', new_key('\n Options', 'automatic_purchase'), {
                            'Ignore pistol round',
                            'Only $16k',
                        }
                    )
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

            selector.tab_label = menu.new(
                ui.new_label, 'AA', 'Fake lag', new_key('\n Tab Label', 'antiaim selector')
            )

            selector.tab = menu.new(
                ui.new_combobox, 'AA', 'Fake lag', new_key('\n Tab', 'antiaim selector'), {'Builder', 'Features'}
            )

            selector.separator2 = menu.new(
                ui.new_label, 'AA', 'Fake lag', new_key('\n Separator2', 'antiaim selector')
            )

            local callbacks do
                local ref_menu_color = ui.reference(
                    'Misc', 'Settings', 'Menu color'
                )

                local function get_label_tab()
                    local name

                    if selector.tab:get() == 'Builder' then
                        name = string.format(
                            'Type \a%s ~  \a%s%s',
                            lock_clr(),
                            reference.get_color(true),
                            ''
                        )
                    end

                    if selector.tab:get() == 'Features' then
                        name = string.format(
                            'Type \a%s ~  \a%s%s',
                            lock_clr(),
                            reference.get_color(true),
                            ''
                        )
                    end

                    selector.tab_label:set(name)
                end

                local function on_menu_color(item)
                    get_label_tab()
                end

                selector.tab:set_callback(
                    get_label_tab
                )

                ui_callback.set(
                    ref_menu_color,
                    on_menu_color
                )

                get_label_tab()
            end
        end

        local builder = { } do
            antiaim.builder = builder

            local current_state = conditions[1]

            local function create_defensive_items(state)
                local items = { }

                local function hash(key)
                    return state .. ':' .. ':defensive_' .. key
                end

                items.force_defensive = config_system.push(
                    'Builder', hash 'force_defensive', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('Force defensive', hash 'force_defensive')
                    )
                )

                items.enabled = config_system.push(
                    'Builder', hash 'enabled', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('Defensive anti-aim', hash 'enabled')
                    )
                )

                items.type = config_system.push(
                    'Builder', hash 'type', menu.new(
                        ui.new_combobox, 'AA', 'Other', new_key('\n Type', hash 'type'), {
                            'Default',
                            'Flick',
                            'Flick Legit'
                        }
                    )
                )

                local wrapper_pitch_label = theme_controller.wrap(new_key('Pitch  ${»}', hash 'pitch'))

                items.pitch_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_pitch_label()
                )

                theme_controller.push(items.pitch_label, wrapper_pitch_label)

                items.pitch = config_system.push(
                    'Builder', hash 'pitch', menu.new(
                        ui.new_combobox, 'AA', 'Other', new_key('\n Pitch', hash 'pitch'), {
                            'Off',
                            'Static',
                            'Switch',
                            'Spin',
                            'Random'
                        }
                    )
                )

                local wrapper_pitch_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'pitch_offset'))

                items.pitch_offset_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_pitch_offset_label()
                )

                theme_controller.push(items.pitch_offset_label, wrapper_pitch_offset_label)


                items.pitch_offset = config_system.push(
                    'Builder', hash 'pitch_offset ', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n', hash 'pitch_offset '), -89, 89, 0, true, '°'
                    )
                )

                local wrapper_pitch_label_1 = theme_controller.wrap(new_key('From ${•}', hash 'pitch'))

                items.pitch_label_1 = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_pitch_label_1()
                )

                theme_controller.push(items.pitch_label_1, wrapper_pitch_label_1)


                items.pitch_offset_1 = config_system.push(
                    'Builder', hash 'pitch_offset_1', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n', hash 'pitch_offset_1'), -89, 89, 0, true, '°'
                    )
                )

                local wrapper_pitch_label_2 = theme_controller.wrap(new_key('To ${•}', hash 'pitch'))

                items.pitch_label_2 = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_pitch_label_2()
                )

                theme_controller.push(items.pitch_label_2, wrapper_pitch_label_2)

                items.pitch_offset_2 = config_system.push(
                    'Builder', hash 'pitch_offset_2', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n', hash 'pitch_offset_2'), -89, 89, 0, true, '°'
                    )
                )

                local wrapper_pitch_offset_delay_label = theme_controller.wrap(new_key('Delay ${•}', hash 'pitch_offset_delay'))

                items.pitch_offset_delay_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_pitch_offset_delay_label()
                )

                theme_controller.push(items.pitch_offset_delay_label, wrapper_pitch_offset_delay_label)

                items.pitch_offset_delay = config_system.push(
                    'Builder', hash 'pitch_offset_delay', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Delay', hash 'pitch_offset_delay'), 1, 10, 1, true, 't', 1, {
                            [1] = 'Off'
                        }
                    )
                )

                local wrapper_pitch_offset_speed_label = theme_controller.wrap(new_key('Speed ${•}', hash 'pitch_offset_speed'))

                items.pitch_offset_speed_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_pitch_offset_speed_label()
                )

                theme_controller.push(items.pitch_offset_speed_label, wrapper_pitch_offset_speed_label)

                items.pitch_offset_speed = config_system.push(
                    'Builder', hash 'pitch_offset_speed', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Speed', hash 'pitch_offset_speed'), 0, 20, 0, true, nil, 1
                    )
                )

                items.yaw = config_system.push(
                    'Builder', hash 'yaw', menu.new(
                        ui.new_combobox, 'AA', 'Other', new_key('Yaw', hash 'yaw'), {
                            'Off',
                            'Static',
                            'Switch',
                            'Spin',
                            'Random',
                            'Left / Right'
                        }
                    )
                )

                local wrapper_yaw_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'yaw_offset'))

                items.yaw_offset_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_offset_label()
                )

                theme_controller.push(items.yaw_offset_label, wrapper_yaw_offset_label)

                local wrapper_yaw_label_1 = theme_controller.wrap(new_key('From ${•}', hash 'yaw'))

                items.yaw_label_1 = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_label_1()
                )

                theme_controller.push(items.yaw_label_1, wrapper_yaw_label_1)

                -- alternate captions for the same two sliders when the yaw
                -- mode is 'Left / Right' (slider 1 = left, slider 2 = right)
                local wrapper_yaw_label_left = theme_controller.wrap(new_key('Left ${•}', hash 'yaw'))

                items.yaw_label_left = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_label_left()
                )

                theme_controller.push(items.yaw_label_left, wrapper_yaw_label_left)

                items.yaw_offset_1 = config_system.push(
                    'Builder', hash 'yaw_offset_1', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n', hash 'yaw_offset_1'), -180, 180, 0, true, '°'
                    )
                )

                local wrapper_yaw_label_2 = theme_controller.wrap(new_key('To ${•}', hash 'yaw'))

                items.yaw_label_2 = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_label_2()
                )

                theme_controller.push(items.yaw_label_2, wrapper_yaw_label_2)

                local wrapper_yaw_label_right = theme_controller.wrap(new_key('Right ${•}', hash 'yaw'))

                items.yaw_label_right = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_label_right()
                )

                theme_controller.push(items.yaw_label_right, wrapper_yaw_label_right)

                items.yaw_offset_2 = config_system.push(
                    'Builder', hash 'yaw_offset_2', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n', hash 'yaw_offset_2'), -180, 180, 0, true, '°'
                    )
                )

                local wrapper_yaw_offset_delay_label = theme_controller.wrap(new_key('Delay ${•}', hash 'yaw_offset_delay'))

                items.yaw_offset_delay_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_offset_delay_label()
                )

                theme_controller.push(items.yaw_offset_delay_label, wrapper_yaw_offset_delay_label)


                items.yaw_offset_delay = config_system.push(
                    'Builder', hash 'yaw_offset_delay', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Delay', hash 'yaw_offset_delay'), 1, 10, 1, true, 't', 1, {
                            [1] = 'Off'
                        }
                    )
                )

                items.yaw_offset = config_system.push(
                    'Builder', hash 'yaw_offset', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n', hash 'yaw_offset'), -180, 180, 0, true, '°', 1
                    )
                )

                local wrapper_yaw_random_def_label = theme_controller.wrap(new_key('Randomization ${•}', hash 'yaw_random_def'))

                items.yaw_random_def_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_random_def_label()
                )

                theme_controller.push(items.yaw_random_def_label, wrapper_yaw_random_def_label)

                items.yaw_random_def = config_system.push(
                    'Builder', hash 'yaw_random_def', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Randomization', hash 'yaw_random_def'), 0, 30, 0, true, '°'
                    )
                )

                local wrapper_body_yaw_def_label = theme_controller.wrap(new_key('Body yaw ${»}', hash 'body_yaw_def'))

                items.body_yaw_def_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_body_yaw_def_label()
                )

                theme_controller.push(items.body_yaw_def_label, wrapper_body_yaw_def_label)

                items.body_yaw_def = config_system.push(
                    'Builder', hash 'body_yaw_def', menu.new(
                        ui.new_combobox, 'AA', 'Other', new_key('\n Body yaw', hash 'body_yaw_def'), {
                            'Inherit',
                            'Static',
                            'Jitter',
                            'Off'
                        }
                    )
                )

                local wrapper_body_yaw_offset_def_label = theme_controller.wrap(new_key('Offset ${•}', hash 'body_yaw_offset_def'))

                items.body_yaw_offset_def_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_body_yaw_offset_def_label()
                )

                theme_controller.push(items.body_yaw_offset_def_label, wrapper_body_yaw_offset_def_label)

                items.body_yaw_offset_def = config_system.push(
                    'Builder', hash 'body_yaw_offset_def', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Offset', hash 'body_yaw_offset_def'), -180, 180, 90, true, '°'
                    )
                )

                local wrapper_yaw_offset_flick_label = theme_controller.wrap(new_key('Yaw offset ${•}', hash 'flick_yaw_offset'))

                items.yaw_offset_flick_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_offset_flick_label()
                )

                theme_controller.push(items.yaw_offset_flick_label, wrapper_yaw_offset_flick_label)

                items.yaw_offset_flick = config_system.push(
                    'Builder', hash 'flick_yaw_offset', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Yaw offset', hash 'flick_yaw_offset'), 0, 180, 90, true, '°', 1
                    )
                )

                local wrapper_yaw_offset_flick_legit_label = theme_controller.wrap(new_key('Yaw offset ${•}', hash 'flick_legit_yaw_offset'))

                items.yaw_offset_flick_legit_label = menu.new(
                    ui.new_label, 'AA', 'Other', wrapper_yaw_offset_flick_legit_label()
                )

                theme_controller.push(items.yaw_offset_flick_legit_label, wrapper_yaw_offset_flick_legit_label)

                items.yaw_offset_flick_legit = config_system.push(
                    'Builder', hash 'flick_legit_yaw_offset', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Yaw offset', hash 'flick_legit_yaw_offset'), 0, 60, 30, true, '°', 1
                    )
                )

                return items
            end

            local function create_builder_items(state, std_key)
                local items = { }

                local is_shared = state == 'Shared'
                local is_legit_aa = state == 'Legit AA'

                local is_freestanding = state == 'Freestanding'
                local is_manual_aa = state == 'Manual AA'

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
                    local enabled_name = string.format(
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

                if is_legit_aa then
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

                    local wrapper_yaw_type_label = theme_controller.wrap(new_key('Yaw ${»}', hash 'yaw_type'))

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
                                ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Randomization', hash 'yaw_random'), 0, 30, 0, true, '°'
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
                            local wrapper_yaw_left_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'yaw_left_offset'))

                            items.yaw_left_offset_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_left_offset_label()
                            )

                            theme_controller.push(items.yaw_left_offset_label, wrapper_yaw_left_offset_label)

                            items.yaw_left_offset = config_system.push(
                                'Builder', hash 'yaw_left_offset', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Offset', hash 'yaw_left_offset'), -180, 180, 0, true, '°'
                                )
                            )

                            local wrapper_yaw_left_random_label = theme_controller.wrap(new_key('Randomization ${•}', hash 'yaw_left_random'))

                            items.yaw_left_random_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_left_random_label()
                            )

                            theme_controller.push(items.yaw_left_random_label, wrapper_yaw_left_random_label)

                            items.yaw_left_random = config_system.push(
                                'Builder', hash 'yaw_left_random', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Randomization', hash 'yaw_left_random'), 0, 30, 0, true, '°'
                                )
                            )

                            items.yaw_left_delay = { }

                            for i = 1, 3 do
                                local hash_label = hash(string.format('yaw_left_label_%s', i))
                                local hash_delay = hash(string.format('yaw_left_delay_%s', i))

                                local wrapper_label = theme_controller.wrap(new_key('Delay ${•}', hash_label))

                                local min_delay = 1
                                local max_delay = 10

                                if i ~= 1 then
                                    min_delay = 0
                                end

                                local item_label = menu.new(
                                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_label()
                                )

                                local item_delay = config_system.push(
                                    'Builder', hash_delay, menu.new(
                                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Delay', hash_delay), min_delay, max_delay, min_delay, true, 't', 1, {
                                            [min_delay] = 'Off'
                                        }
                                    )
                                )

                                theme_controller.push(item_label, wrapper_label)

                                items.yaw_left_delay[i] = {
                                    label = item_label,
                                    delay = item_delay
                                }
                            end

                            local wrapper_yaw_left_dmode_label = theme_controller.wrap(new_key('Delay mode ${»}', hash 'yaw_left_delay_mode'))

                            items.yaw_left_delay_mode_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_left_dmode_label()
                            )

                            theme_controller.push(items.yaw_left_delay_mode_label, wrapper_yaw_left_dmode_label)

                            items.yaw_left_delay_mode = config_system.push(
                                'Builder', hash 'yaw_left_delay_mode', menu.new(
                                    ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Delay mode', hash 'yaw_left_delay_mode'), {
                                        'Steps',
                                        'Min / Max'
                                    }
                                )
                            )

                            local wrapper_yaw_left_dmin_label = theme_controller.wrap(new_key('Minimum Delay ${•}', hash 'yaw_left_delay_min'))

                            items.yaw_left_delay_min_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_left_dmin_label()
                            )

                            theme_controller.push(items.yaw_left_delay_min_label, wrapper_yaw_left_dmin_label)

                            items.yaw_left_delay_min = config_system.push(
                                'Builder', hash 'yaw_left_delay_min', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Minimum Delay', hash 'yaw_left_delay_min'), 0, 10, 0, true, 't', 1, {
                                        [0] = 'Off'
                                    }
                                )
                            )

                            local wrapper_yaw_left_dmax_label = theme_controller.wrap(new_key('Maximum Delay ${•}', hash 'yaw_left_delay_max'))

                            items.yaw_left_delay_max_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_left_dmax_label()
                            )

                            theme_controller.push(items.yaw_left_delay_max_label, wrapper_yaw_left_dmax_label)

                            items.yaw_left_delay_max = config_system.push(
                                'Builder', hash 'yaw_left_delay_max', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Maximum Delay', hash 'yaw_left_delay_max'), 0, 10, 0, true, 't', 1, {
                                        [0] = 'Off'
                                    }
                                )
                            )
                        end

                        local right_yaw do
                            local wrapper_yaw_right_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'yaw_right_offset'))

                            items.yaw_right_offset_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_right_offset_label()
                            )

                            theme_controller.push(items.yaw_right_offset_label, wrapper_yaw_right_offset_label)

                            items.yaw_right_offset = config_system.push(
                                'Builder', hash 'yaw_right_offset', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Offset', hash 'yaw_right_offset'), -180, 180, 0, true, '°'
                                )
                            )

                            local wrapper_yaw_right_random_label = theme_controller.wrap(new_key('Randomization ${•}', hash 'yaw_right_random'))

                            items.yaw_right_random_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_right_random_label()
                            )

                            theme_controller.push(items.yaw_right_random_label, wrapper_yaw_right_random_label)

                            items.yaw_right_random = config_system.push(
                                'Builder', hash 'yaw_right_random', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Randomization', hash 'yaw_right_random'), 0, 30, 0, true, '°'
                                )
                            )

                            items.yaw_right_delay = { }

                            for i = 1, 3 do
                                local hash_label = hash(string.format('yaw_right_label_%s', i))
                                local hash_delay = hash(string.format('yaw_right_delay_%s', i))

                                local wrapper_label = theme_controller.wrap(new_key('Delay ${•}', hash_label))

                                local min_delay = 1
                                local max_delay = 10

                                if i ~= 1 then
                                    min_delay = 0
                                end

                                local item_label = menu.new(
                                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_label()
                                )

                                local item_delay = config_system.push(
                                    'Builder', hash_delay, menu.new(
                                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Delay', hash_delay), min_delay, max_delay, min_delay, true, 't', 1, {
                                            [min_delay] = 'Off'
                                        }
                                    )
                                )

                                theme_controller.push(item_label, wrapper_label)

                                items.yaw_right_delay[i] = {
                                    label = item_label,
                                    delay = item_delay
                                }
                            end

                            local wrapper_yaw_right_dmode_label = theme_controller.wrap(new_key('Delay mode ${»}', hash 'yaw_right_delay_mode'))

                            items.yaw_right_delay_mode_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_right_dmode_label()
                            )

                            theme_controller.push(items.yaw_right_delay_mode_label, wrapper_yaw_right_dmode_label)

                            items.yaw_right_delay_mode = config_system.push(
                                'Builder', hash 'yaw_right_delay_mode', menu.new(
                                    ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Delay mode', hash 'yaw_right_delay_mode'), {
                                        'Steps',
                                        'Min / Max'
                                    }
                                )
                            )

                            local wrapper_yaw_right_dmin_label = theme_controller.wrap(new_key('Minimum Delay ${•}', hash 'yaw_right_delay_min'))

                            items.yaw_right_delay_min_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_right_dmin_label()
                            )

                            theme_controller.push(items.yaw_right_delay_min_label, wrapper_yaw_right_dmin_label)

                            items.yaw_right_delay_min = config_system.push(
                                'Builder', hash 'yaw_right_delay_min', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Minimum Delay', hash 'yaw_right_delay_min'), 0, 10, 0, true, 't', 1, {
                                        [0] = 'Off'
                                    }
                                )
                            )

                            local wrapper_yaw_right_dmax_label = theme_controller.wrap(new_key('Maximum Delay ${•}', hash 'yaw_right_delay_max'))

                            items.yaw_right_delay_max_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_yaw_right_dmax_label()
                            )

                            theme_controller.push(items.yaw_right_delay_max_label, wrapper_yaw_right_dmax_label)

                            items.yaw_right_delay_max = config_system.push(
                                'Builder', hash 'yaw_right_delay_max', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Maximum Delay', hash 'yaw_right_delay_max'), 0, 10, 0, true, 't', 1, {
                                        [0] = 'Off'
                                    }
                                )
                            )
                        end
                    end

                    items.separator = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', hash 'yaw')
                    )

                    local yaw_jitter do
                        local jitter_option do
                            local wrapper_yaw_jitter_label = theme_controller.wrap(new_key('Yaw jitter ${»}', hash 'yaw_jitter'))

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
                                        'Skitter',
                                        'X-way',
                                        'Sway',
                                        'Sequence'
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

                            local wrapper_x_way_offset_1_label = theme_controller.wrap(new_key('First Offset ${•}', hash 'x_way_offset'))

                            items.x_way_offset_1_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_1_label()
                            )

                            theme_controller.push(items.x_way_offset_1_label, wrapper_x_way_offset_1_label)

                            items.x_way_offset_1 = config_system.push(
                                'Builder', hash 'x_way_offset_1', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Second Offset', hash 'x_way_offset'), -180, 180, 0, true, '°'
                                )
                            )

                            local wrapper_x_way_offset_2_label = theme_controller.wrap(new_key('Second Offset ${•}', hash 'x_way_offset'))

                            items.x_way_offset_2_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_2_label()
                            )

                            theme_controller.push(items.x_way_offset_2_label, wrapper_x_way_offset_2_label)

                            items.x_way_offset_2 = config_system.push(
                                'Builder', hash 'x_way_offset_2', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n First Offset', hash 'x_way_offset'), -180, 180, 0, true, '°'
                                )
                            )

                            local wrapper_x_way_offset_3_label = theme_controller.wrap(new_key('Third Offset ${•}', hash 'x_way_offset'))

                            items.x_way_offset_3_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_3_label()
                            )

                            theme_controller.push(items.x_way_offset_3_label, wrapper_x_way_offset_3_label)

                            items.x_way_offset_3 = config_system.push(
                                'Builder', hash 'x_way_offset_3', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n First Offset', hash 'x_way_offset'), -180, 180, 0, true, '°'
                                )
                            )

                            local wrapper_x_way_offset_4_label = theme_controller.wrap(new_key('Fourth offset ${•}', hash 'x_way_offset'))

                            items.x_way_offset_4_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_4_label()
                            )

                            theme_controller.push(items.x_way_offset_4_label, wrapper_x_way_offset_4_label)

                            items.x_way_offset_4 = config_system.push(
                                'Builder', hash 'x_way_offset_4', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Fourth offset', hash 'x_way_offset'), -180, 180, 0, true, '°'
                                )
                            )

                            local wrapper_x_way_offset_5_label = theme_controller.wrap(new_key('Fifth offset ${•}', hash 'x_way_offset'))

                            items.x_way_offset_5_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_x_way_offset_5_label()
                            )

                            theme_controller.push(items.x_way_offset_5_label, wrapper_x_way_offset_5_label)

                            items.x_way_offset_5 = config_system.push(
                                'Builder', hash 'x_way_offset_5', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Fifth offset', hash 'x_way_offset'), -180, 180, 0, true, '°'
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

                        local sway_cycle do
                            local wrapper_sway_cycle_label = theme_controller.wrap(new_key('Cycle ${•}', hash 'sway_cycle'))

                            items.sway_cycle_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_sway_cycle_label()
                            )

                            theme_controller.push(items.sway_cycle_label, wrapper_sway_cycle_label)

                            items.sway_cycle = config_system.push(
                                'Builder', hash 'sway_cycle', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Cycle', hash 'sway_cycle'), 4, 64, 16, true, 't'
                                )
                            )
                        end

                        local jitter_delay do
                            local wrapper_jitter_delay_min_label = theme_controller.wrap(new_key('Minimum Delay ${•}', hash 'jitter_delay_min'))

                            items.jitter_delay_min_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_jitter_delay_min_label()
                            )

                            theme_controller.push(items.jitter_delay_min_label, wrapper_jitter_delay_min_label)

                            items.jitter_delay_min = config_system.push(
                                'Builder', hash 'jitter_delay_min', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Minimum Delay', hash 'jitter_delay_min'), 0, 10, 0, true, 't', 1, {
                                        [0] = 'Off'
                                    }
                                )
                            )

                            local wrapper_jitter_delay_max_label = theme_controller.wrap(new_key('Maximum Delay ${•}', hash 'jitter_delay_max'))

                            items.jitter_delay_max_label = menu.new(
                                ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_jitter_delay_max_label()
                            )

                            theme_controller.push(items.jitter_delay_max_label, wrapper_jitter_delay_max_label)

                            items.jitter_delay_max = config_system.push(
                                'Builder', hash 'jitter_delay_max', menu.new(
                                    ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Maximum Delay', hash 'jitter_delay_max'), 0, 10, 0, true, 't', 1, {
                                        [0] = 'Off'
                                    }
                                )
                            )
                        end
                    end

                    items.separator2 = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator2', hash 'jitter')
                    )
                end

                local wrapper_body_yaw_label = theme_controller.wrap(new_key('Body yaw  ${»}', hash 'body_yaw'))

                items.body_yaw_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_yaw_label()
                )

                theme_controller.push(items.body_yaw_label, wrapper_body_yaw_label)

                items.body_yaw = config_system.push(
                    'Builder', hash 'body_yaw', menu.new(
                        ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n Body yaw', hash 'body_yaw'), {
                            'Off',
                            'Opposite',
                            'Static',
                            'Jitter',
                            'Jitter Random'
                        }
                    )
                )

                local wrapper_body_yaw_offset_label = theme_controller.wrap(new_key('Offset ${•}', hash 'body_yaw_offset'))

                items.body_yaw_offset_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_body_yaw_offset_label()
                )

                theme_controller.push(items.body_yaw_offset_label, wrapper_body_yaw_offset_label)


                items.body_yaw_offset = config_system.push(
                    'Builder', hash 'body_yaw_offset', menu.new(
                        ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Offset', hash 'body_yaw_offset'), -180, 180, 0, true, '°'
                    )
                )

                items.freestanding_body_yaw = config_system.push(
                    'Builder', hash 'freestanding_body_yaw', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key(
                            'Freestanding body yaw', hash 'freestanding_body_yaw'
                        )
                    )
                )

                if state ~= 'Fakelag' then
                    local wrapper_delay_from_label = theme_controller.wrap(new_key('Delay ${•}', hash 'delay'))

                    items.delay_from_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_delay_from_label()
                    )

                    theme_controller.push(items.delay_from_label, wrapper_delay_from_label)

                    items.delay_from = config_system.push(
                        'Builder', hash 'delay_from', menu.new(
                            ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Delay', hash 'delay'), 1, 11, 1, true, 't', 1, {
                                [1] = 'Off',
                                [11] = 'Random'
                            }
                        )
                    )

                    local wrapper_delay_to_label = theme_controller.wrap(new_key('Delay ${•}', hash 'delay_second'))

                    items.delay_to_label = menu.new(
                        ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_delay_to_label()
                    )

                    theme_controller.push(items.delay_to_label, wrapper_delay_to_label)

                    items.delay_to = config_system.push(
                        'Builder', hash 'delay_to', menu.new(
                            ui.new_slider, 'AA', 'Anti-aimbot angles', new_key('\n Delay', hash 'delay_second'), 0, 10, 0, true, 't', 1, {
                                [0] = 'Off',
                            }
                        )
                    )
                end

                return items
            end

            local function get_current_state()
                return string.format(
                    'State  \a%s~  ${%s}',
                    lock_clr(),
                    current_state
                )
            end

            local petarda = theme_controller.wrap(new_key(
                get_current_state(),
                'builder'
            ))

            builder.state_label = menu.new(
                ui.new_label, 'AA', 'Anti-aimbot angles', petarda()
            )

            theme_controller.push(builder.state_label, petarda)

            builder.state = menu.new(
                ui.new_combobox, 'AA', 'Anti-aimbot angles', new_key('\n State', 'builder'), conditions
            )

            for i = 1, #conditions do
                local state = conditions[i]

                local items = { }

                items.angles = create_builder_items(
                    state, nil
                )

                if state ~= 'Fakelag' then
                    items.defensive = create_defensive_items(state)
                end

                builder[state] = items
            end

            local callbacks do
                local function get_current_state_clr()
                    return string.format(
                        'State  \a%s~\a%s  %s',
                        lock_clr(),
                        reference.get_color(true),
                        current_state
                    )
                end

                local function on_element_update(items)
                    local value = items:get()

                    current_state = value

                    builder.state_label:set(get_current_state_clr())
                end

                builder.state:set_callback(on_element_update, true)
            end
        end

        local features = { } do
            antiaim.features = features

            local HOTKEY_MODE = {
                [0] = 'Always on',
                [1] = 'On hotkey',
                [2] = 'Toggle',
                [3] = 'Off hotkey'
            }

            local function get_hotkey_value(_, mode, key)
                return HOTKEY_MODE[mode], key or 0
            end

            local avoid_backstab = { } do
                features.avoid_backstab = avoid_backstab

                avoid_backstab.checkbox = config_system.push(
                    'Features', 'avoid_backstab.enabled', menu.new(
                        ui.new_checkbox, 'AA', 'Fake lag', new_key('Avoid backstab', 'avoid_backstab')
                    )
                )

                avoid_backstab.distance = config_system.push(
                    'Features', 'avoid_backstab.distance', menu.new(
                        ui.new_slider, 'AA', 'Fake lag', new_key('\n Distance', 'avoid_backstab'), 150, 320, 240, true, 'u'
                    )
                )

                avoid_backstab.separator = menu.new(
                    ui.new_label, 'AA', 'Fake lag', new_key('\n Separator', 'avoid_backstab')
                )
            end

            features.vanish = config_system.push(
                'Rage', 'warmup_round_end.select', menu.new(
                    ui.new_multiselect, 'AA', 'Fake Lag', new_key('Vanish Mode', 'warmup_round_end'), {"On Warmup", "No Enemies"}
                )
            )

            local manual_yaw = { } do
                features.manual_yaw = manual_yaw

                manual_yaw.checkbox = config_system.push(
                    'Features', 'manual_yaw.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Manual Yaw', 'manual_yaw')
                    )
                )

                manual_yaw.options = config_system.push(
                    'Features', 'manual_yaw.options', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Options', 'manual_yaw'), {
                            'Disable yaw modifiers',
                            'Freestanding body',
                            'Spam manuals'
                        }
                    )
                )

                local wrapper_forward_label = theme_controller.wrap(new_key('Forward  ${}', 'manual_yaw'))

                manual_yaw.forward_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_forward_label()
                )

                theme_controller.push(manual_yaw.forward_label, wrapper_forward_label)

                manual_yaw.forward = config_system.push(
                    'Features', 'manual_yaw.forward', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Forward', 'manual_yaw'), true
                    )
                )

                local wrapper_left_label = theme_controller.wrap(new_key('Left  ${}', 'manual_yaw'))

                manual_yaw.left_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_left_label()
                )

                theme_controller.push(manual_yaw.left_label, wrapper_left_label)

                manual_yaw.left = config_system.push(
                    'Features', 'manual_yaw.left', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Left', 'manual_yaw'), true
                    )
                )

                manual_yaw.left:set 'On hotkey'

                local wrapper_right_label = theme_controller.wrap(new_key('Right  ${}', 'manual_yaw'))

                manual_yaw.right_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_right_label()
                )

                theme_controller.push(manual_yaw.right_label, wrapper_right_label)

                manual_yaw.right = config_system.push(
                    'Features', 'manual_yaw.right', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Right', 'manual_yaw'), true
                    )
                )

                manual_yaw.right:set 'On hotkey'

                local wrapper_reset_label = theme_controller.wrap(new_key('Reset  ${}', 'manual_yaw'))

                manual_yaw.reset_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_reset_label()
                )

                theme_controller.push(manual_yaw.reset_label, wrapper_reset_label)

                manual_yaw.reset = config_system.push(
                    'Features', 'manual_yaw.reset', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Reset', 'manual_yaw'), true
                    )
                )

                manual_yaw.separator = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'manual_yaw')
                )

                manual_yaw.reset:set 'On hotkey'

                manual_yaw.left:set 'Toggle'
                manual_yaw.right:set 'Toggle'
                manual_yaw.forward:set 'Toggle'
            end

            local freestanding = { } do
                features.freestanding = freestanding

                freestanding.checkbox = config_system.push(
                    'Features', 'freestanding.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Freestanding', 'freestanding')
                    )
                )

                freestanding.hotkey = config_system.push(
                    'Features', 'freestanding.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Hotkey', 'freestanding'), true
                    )
                )

                freestanding.disablers = config_system.push(
                    'Features', 'freestanding.disablers', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Disablers', 'freestanding'), {
                            'Standing',
                            'Moving',
                            'Slow Walk',
                            'Crouching',
                            'Air'
                        }
                    )
                )

                freestanding.separator = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'freestanding')
                )
            end

            local edge_yaw = { } do
                features.edge_yaw = edge_yaw

                edge_yaw.checkbox = config_system.push(
                    'Features', 'edge_yaw.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Edge Yaw', 'edge_yaw')
                    )
                )

                edge_yaw.hotkey = config_system.push(
                    'Features', 'edge_yaw.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Anti-aimbot angles', new_key('Hotkey', 'edge_yaw'), true
                    )
                )

                edge_yaw.disablers = config_system.push(
                    'Features', 'edge_yaw.disablers', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Disablers', 'edge_yaw'), {
                            'Standing',
                            'Moving',
                            'Slow Walk',
                            'Crouching',
                            'Air'
                        }
                    )
                )

                edge_yaw.separator = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'edge_yaw')
                )
            end

            local break_lc_triggers = { } do
                features.break_lc_triggers = break_lc_triggers

                break_lc_triggers.checkbox = config_system.push(
                    'Features', 'break_lc_triggers.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', 'Break LC triggers'
                    )
                )

                break_lc_triggers.states = config_system.push(
                    'Features', 'break_lc_triggers.states', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n States', 'force_break_lc_triggers'), {
                            'Flashed',
                            'Reloading',
                            'Taking damage'
                        }
                    )
                )

                break_lc_triggers.separator = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', new_key('\n Separator', 'force_break_lc_triggers')
                )

                lock_unselection(break_lc_triggers.states)
            end

            local safe_head = { } do
                features.safe_head = safe_head

                safe_head.checkbox = config_system.push(
                    'Features', 'safe_head.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Anti-aimbot angles', new_key('Safe Head', 'safe_head')
                    )
                )

                safe_head.conditions = config_system.push(
                    'Features', 'safe_head.conditions', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Conditions', 'safe_head'), {
                            'Standing',
                            'Crouch',
                            'Air crouch',
                            'Air crouch knife',
                            'Air crouch taser',
                            'Distance'
                        }
                    )
                )

                local wrapper_options_label = theme_controller.wrap(new_key('Options  ${~}', 'manual_yaw'))

                safe_head.options_label = menu.new(
                    ui.new_label, 'AA', 'Anti-aimbot angles', wrapper_options_label()
                )

                theme_controller.push(safe_head.options_label, wrapper_options_label)

                safe_head.options = config_system.push(
                    'Features', 'safe_head.options', menu.new(
                        ui.new_multiselect, 'AA', 'Anti-aimbot angles', new_key('\n Options', 'safe_head'), {'E Spam while active'}
                    )
                )
            end

            local fakelag = { } do
                features.fakelag = fakelag

                fakelag.checkbox = config_system.push(
                    'Features', 'fakelag.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('Fake lag', 'fakelag')
                    )
                )

                fakelag.hotkey = config_system.push(
                    'Features', 'fakelag.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Other', new_key('Hotkey', 'fakelag'), true
                    )
                )

                fakelag.type = config_system.push(
                    'Features', 'fakelag.type', menu.new(
                        ui.new_combobox, 'AA', 'Other', new_key('\n Type', 'fakelag'), {
                            'Dynamic',
                            'Maximum',
                            'Fluctuate'
                        }
                    )
                )

                local wrapper_variance_label = theme_controller.wrap(new_key('Variance ${•}', 'fakelag'))

                    fakelag.variance_label = menu.new(
                        ui.new_label, 'AA', 'Other', wrapper_variance_label()
                    )

                theme_controller.push(fakelag.variance_label, wrapper_variance_label)

                fakelag.variance = config_system.push(
                    'Features', 'fakelag.variance', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Variance', 'fakelag'), 0, 100, 0, true, '%'
                    )
                )

                local wrapper_limit_label = theme_controller.wrap(new_key('Limit ${•}', 'fakelag'))

                    fakelag.limit_label = menu.new(
                        ui.new_label, 'AA', 'Other', wrapper_limit_label()
                    )

                theme_controller.push(fakelag.limit_label, wrapper_limit_label)

                fakelag.limit = config_system.push(
                    'Features', 'fakelag.limit', menu.new(
                        ui.new_slider, 'AA', 'Other', new_key('\n Limit', 'fakelag'), 1, 15, 1, true, 't'
                    )
                )

                fakelag.separator = menu.new(
                    ui.new_label, 'AA', 'Other', new_key('\n Separator', 'fakelag')
                )

                fakelag.checkbox:set(ui.get(reference.antiaim.fake_lag.enabled[1]))
                fakelag.hotkey:set(get_hotkey_value(ui.get(reference.antiaim.fake_lag.enabled[2])))

                fakelag.type:set(ui.get(reference.antiaim.fake_lag.amount))

                fakelag.variance:set(ui.get(reference.antiaim.fake_lag.variance))
                fakelag.limit:set(math.max(1, math.min(15, ui.get(reference.antiaim.fake_lag.limit))))
            end

            local slow_motion = { } do
                features.slow_motion = slow_motion

                slow_motion.checkbox = config_system.push(
                    'Features', 'slow_motion.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('Slow Motion', 'slow_motion')
                    )
                )

                slow_motion.hotkey = config_system.push(
                    'Features', 'slow_motion.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Other', new_key('Hotkey', 'slow_motion'), true
                    )
                )

                slow_motion.checkbox:set(ui.get(reference.antiaim.other.slow_motion[1]))
                slow_motion.hotkey:set(get_hotkey_value(ui.get(reference.antiaim.other.slow_motion[2])))
            end

            local osaa = { } do
                features.osaa = osaa

                osaa.checkbox = config_system.push(
                    'Features', 'osaa.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('\aB6B665FFOn shot anti-aim', 'osaa')
                    )
                )

                osaa.hotkey = config_system.push(
                    'Features', 'osaa.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Other', new_key('Hotkey', 'osaa'), true
                    )
                )

                osaa.checkbox:set(ui.get(reference.antiaim.other.on_shot_antiaim[1]))
                osaa.hotkey:set(get_hotkey_value(ui.get(reference.antiaim.other.on_shot_antiaim[2])))
            end

            local fake_peek = { } do
                features.fake_peek = fake_peek

                fake_peek.checkbox = config_system.push(
                    'Features', 'fake_peek.checkbox', menu.new(
                        ui.new_checkbox, 'AA', 'Other', new_key('\aB6B665FFFake peek', 'fake_peek')
                    )
                )

                fake_peek.hotkey = config_system.push(
                    'Features', 'fake_peek.hotkey', menu.new(
                        ui.new_hotkey, 'AA', 'Other', new_key('Hotkey', 'fake_peek'), true
                    )
                )

                fake_peek.checkbox:set(ui.get(reference.antiaim.other.fake_peek[1]))
                fake_peek.hotkey:set(get_hotkey_value(ui.get(reference.antiaim.other.fake_peek[2])))
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

        local function update_builder_items(items)
            local angles = items.angles
            local defensive = items.defensive

            if angles ~= nil then
                if angles.enabled ~= nil then
                    menu_logic.set(angles.enabled, true)

                    if not angles.enabled:get() then
                        return
                    end
                end

                if angles.bomb_e_fix ~= nil then
                    menu_logic.set(angles.bomb_e_fix, true)
                end

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

                    if angles.yaw_type:get() == 'Left / Right' then
                        menu_logic.set(angles.separator, true)
                        menu_logic.set(angles.yaw_side_label, true)
                        menu_logic.set(angles.yaw_side, true)

                        if angles.yaw_side:get() == 'Left' then
                            menu_logic.set(angles.yaw_left_offset_label, true)
                            menu_logic.set(angles.yaw_left_offset, true)

                            menu_logic.set(angles.yaw_left_random_label, true)
                            menu_logic.set(angles.yaw_left_random, true)

                            menu_logic.set(angles.yaw_left_delay_mode_label, true)
                            menu_logic.set(angles.yaw_left_delay_mode, true)

                            if angles.yaw_left_delay_mode:get() == 'Min / Max' then
                                menu_logic.set(angles.yaw_left_delay_min_label, true)
                                menu_logic.set(angles.yaw_left_delay_min, true)

                                menu_logic.set(angles.yaw_left_delay_max_label, true)
                                menu_logic.set(angles.yaw_left_delay_max, true)
                            else
                                for i = 1, 3 do
                                    local list = angles.yaw_left_delay[i]

                                    if list == nil then
                                        break
                                    end

                                    menu_logic.set(list.label, true)
                                    menu_logic.set(list.delay, true)

                                    local min_value = (i == 1) and 1 or 0

                                    if list.delay:get() <= min_value then
                                        break
                                    end
                                end
                            end
                        end

                        if angles.yaw_side:get() == 'Right' then
                            menu_logic.set(angles.yaw_right_offset_label, true)
                            menu_logic.set(angles.yaw_right_offset, true)

                            menu_logic.set(angles.yaw_right_random_label, true)
                            menu_logic.set(angles.yaw_right_random, true)

                            menu_logic.set(angles.yaw_right_delay_mode_label, true)
                            menu_logic.set(angles.yaw_right_delay_mode, true)

                            if angles.yaw_right_delay_mode:get() == 'Min / Max' then
                                menu_logic.set(angles.yaw_right_delay_min_label, true)
                                menu_logic.set(angles.yaw_right_delay_min, true)

                                menu_logic.set(angles.yaw_right_delay_max_label, true)
                                menu_logic.set(angles.yaw_right_delay_max, true)
                            else
                                for i = 1, 3 do
                                    local list = angles.yaw_right_delay[i]

                                    if list == nil then
                                        break
                                    end

                                    menu_logic.set(list.label, true)
                                    menu_logic.set(list.delay, true)

                                    local min_value = (i == 1) and 1 or 0

                                    if list.delay:get() <= min_value then
                                        break
                                    end
                                end
                            end
                        end
                    end
                end

                if angles.yaw_jitter ~= nil then
                    menu_logic.set(angles.yaw_jitter_label, true)
                    menu_logic.set(angles.yaw_jitter, true)

                    if angles.yaw_jitter:get() ~= 'Off' then
                        menu_logic.set(angles.jitter_offset_label, true)
                        menu_logic.set(angles.jitter_offset, true)

                        menu_logic.set(angles.jitter_random_label, true)
                        menu_logic.set(angles.jitter_random, true)

                        local jitter_mode = angles.yaw_jitter:get()

                        if jitter_mode ~= 'Random' and jitter_mode ~= 'Sway' then
                            menu_logic.set(angles.jitter_delay_min_label, true)
                            menu_logic.set(angles.jitter_delay_min, true)

                            menu_logic.set(angles.jitter_delay_max_label, true)
                            menu_logic.set(angles.jitter_delay_max, true)
                        end

                        menu_logic.set(angles.separator2, true)
                    end

                    if angles.yaw_jitter:get() == 'X-way' then
                        menu_logic.set(angles.jitter_x_way_label, true)
                        menu_logic.set(angles.jitter_x_way, true)

                        menu_logic.set(angles.x_way_ways_label, true)
                        menu_logic.set(angles.x_way_ways, true)

                        if angles.jitter_x_way:get() == 'Custom' then
                            menu_logic.set(angles.x_way_offset_1_label, true)
                            menu_logic.set(angles.x_way_offset_1, true)

                            menu_logic.set(angles.x_way_offset_2_label, true)
                            menu_logic.set(angles.x_way_offset_2, true)

                            menu_logic.set(angles.x_way_offset_3_label, true)
                            menu_logic.set(angles.x_way_offset_3, true)

                            if angles.x_way_ways:get() >= 4 then
                                menu_logic.set(angles.x_way_offset_4_label, true)
                                menu_logic.set(angles.x_way_offset_4, true)
                            end

                            if angles.x_way_ways:get() == 5 then
                                menu_logic.set(angles.x_way_offset_5_label, true)
                                menu_logic.set(angles.x_way_offset_5, true)
                            end
                        end

                        menu_logic.set(angles.separator2, true)
                    end

                    if angles.yaw_jitter:get() == 'Sway' then
                        menu_logic.set(angles.sway_cycle_label, true)
                        menu_logic.set(angles.sway_cycle, true)
                    end
                end

                if angles.body_yaw ~= nil then
                    menu_logic.set(angles.body_yaw_label, true)
                    menu_logic.set(angles.body_yaw, true)

                    if angles.body_yaw:get() ~= 'Off' then
                        if angles.body_yaw:get() ~= 'Opposite' then
                            menu_logic.set(angles.body_yaw_offset_label, true)
                            menu_logic.set(angles.body_yaw_offset, true)
                        end

                        local is_jitter = (
                            angles.body_yaw:get() == 'Jitter'
                            or angles.body_yaw:get() == 'Jitter Random'
                        )

                        if is_jitter then
                            menu_logic.set(angles.delay_from_label, true)
                            menu_logic.set(angles.delay_from, true)

                            if angles.delay_from:get() > 1 and angles.delay_from:get() ~= 11 then
                                menu_logic.set(angles.delay_to_label, true)
                                menu_logic.set(angles.delay_to, true)
                            end
                        else
                            menu_logic.set(angles.freestanding_body_yaw, true)
                        end
                    end
                end
            end

            if defensive ~= nil then
                if defensive.force_defensive ~= nil then
                    menu_logic.set(defensive.force_defensive, true)
                end

                menu_logic.set(defensive.enabled, true)

                if defensive.enabled:get() then
                    menu_logic.set(defensive.type, true)

                    -- Flick Legit inherits the state pitch by design (it has
                    -- to LOOK like the normal AA), so pitch controls hide
                    local show_pitch = defensive.type:get() ~= 'Flick Legit'

                    if show_pitch then
                        menu_logic.set(defensive.pitch_label, true)
                        menu_logic.set(defensive.pitch, true)
                    end

                    if show_pitch and defensive.pitch:get() ~= 'Off' then
                        menu_logic.set(defensive.pitch_offset_label, true)
                        menu_logic.set(defensive.pitch_offset_1, true)

                        if defensive.pitch:get() ~= 'Static' then
                            menu_logic.set(defensive.pitch_offset_label, false)
                            menu_logic.set(defensive.pitch_label_1, true)
                            menu_logic.set(defensive.pitch_label_2, true)

                            menu_logic.set(defensive.pitch_offset_2, true)
                        end

                        if defensive.pitch:get() == 'Switch' then
                            menu_logic.set(defensive.pitch_offset_label, false)
                            menu_logic.set(defensive.pitch_offset_delay_label, true)
                            menu_logic.set(defensive.pitch_offset_delay, true)
                        end

                        if defensive.pitch:get() == 'Spin' then
                            menu_logic.set(defensive.pitch_offset_label, false)
                            menu_logic.set(defensive.pitch_offset_speed_label, true)
                            menu_logic.set(defensive.pitch_offset_speed, true)
                        end
                    end

                    if defensive.type:get() == 'Flick' then
                        menu_logic.set(defensive.yaw_offset_flick, true)
                        menu_logic.set(defensive.yaw_offset_flick_label, true)
                    end

                    if defensive.type:get() == 'Flick Legit' then
                        menu_logic.set(defensive.yaw_offset_flick_legit_label, true)
                        menu_logic.set(defensive.yaw_offset_flick_legit, true)
                    end

                    if defensive.type:get() == 'Default' then
                        menu_logic.set(defensive.yaw, true)

                        if defensive.yaw:get() ~= 'Off' then
                            local yaw = defensive.yaw:get()

                            local is_not_double =
                                yaw == 'Static'
                                or yaw == 'Spin'

                            if is_not_double then
                                menu_logic.set(defensive.yaw_offset_label, true)
                                menu_logic.set(defensive.yaw_offset, true)
                            end

                            if not is_not_double then
                                if yaw == 'Left / Right' then
                                    menu_logic.set(defensive.yaw_label_left, true)
                                    menu_logic.set(defensive.yaw_label_right, true)
                                else
                                    menu_logic.set(defensive.yaw_label_1, true)
                                    menu_logic.set(defensive.yaw_label_2, true)
                                end

                                menu_logic.set(defensive.yaw_offset_1, true)
                                menu_logic.set(defensive.yaw_offset_2, true)

                                if yaw == 'Switch' or yaw == 'Left / Right' then
                                    menu_logic.set(defensive.yaw_offset_delay_label, true)
                                    menu_logic.set(defensive.yaw_offset_delay, true)
                                end
                            end

                            if yaw ~= 'Spin' and yaw ~= 'Random' then
                                menu_logic.set(defensive.yaw_random_def_label, true)
                                menu_logic.set(defensive.yaw_random_def, true)
                            end
                        end

                        menu_logic.set(defensive.body_yaw_def_label, true)
                        menu_logic.set(defensive.body_yaw_def, true)

                        local body_mode = defensive.body_yaw_def:get()

                        if body_mode == 'Static' or body_mode == 'Jitter' then
                            menu_logic.set(defensive.body_yaw_offset_def_label, true)
                            menu_logic.set(defensive.body_yaw_offset_def, true)
                        end
                    end
                end
            end
        end

        local function force_update_scene()
            menu_logic.set(category_selector.script_name, true)
            menu_logic.set(category_selector.categories_label, true)
            menu_logic.set(category_selector.categories, true)

            local category = category_selector.categories:get()
            local home_tab = home.selector.tab:get()
            local home_other = other.selector.tab:get()
            local home_antiaim = antiaim.selector.tab:get()

            if category == 'Home' then
                local ref = home.selector
                menu_logic.set(ref.separator, true)
                menu_logic.set(ref.tab_label, true)
                menu_logic.set(ref.tab, true)
                menu_logic.set(ref.separator2, true)

                if home.bred_ebaniy.slider ~= nil then
                    local ref_sl = home.bred_ebaniy.slider:get()

                    if ref_sl == 0 then
                        menu_logic.set(home.bred_ebaniy.discord_server, true)
                    end

                    if ref_sl == 1 then
                        menu_logic.set(home.bred_ebaniy.youtube_1, true)
                    end

                    if ref_sl == 2 then
                        menu_logic.set(home.bred_ebaniy.youtube_2, true)
                    end
                end

                menu_logic.set(home.bred_ebaniy.slider_label, true)
                menu_logic.set(home.bred_ebaniy.slider, true)
                menu_logic.set(home.bred_ebaniy.separator, true)

                local is_local = ref.tab:get() == 'Local' do
                    local ref = home.config_local

                    if is_local then
                        menu_logic.set(ref.welcome.user, true)
                        menu_logic.set(ref.welcome.build, true)
                        menu_logic.set(ref.list, true)
                        menu_logic.set(ref.separator, true)
                        menu_logic.set(ref.input, true)

                        menu_logic.set(ref.load, true)
                        menu_logic.set(ref.save, true)
                        menu_logic.set(ref.delete, true)

                        menu_logic.set(ref.author, true)
                        menu_logic.set(ref.data, true)

                        menu_logic.set(ref.import, true)
                        menu_logic.set(ref.export, true)
                    end
                end
            end

            if category == 'Other' then
                local ref = other.selector

                menu_logic.set(ref.separator, true)
                menu_logic.set(ref.tab_label, true)
                menu_logic.set(ref.tab, true)
                menu_logic.set(ref.separator2, true)

                if home_other == 'Ragebot' then
                    local ref = other.rage

                    menu_logic.set(ref.pitch_correction, true)

                    local is_automatic_peek = ref.automatic_peek.checkbox:get() do
                        local ref = other.rage.automatic_peek
                        menu_logic.set(ref.checkbox, true)

                        if is_automatic_peek then
                            menu_logic.set(ref.type, true)
                            menu_logic.set(ref.options_label, true)
                            menu_logic.set(ref.options, true)

                            if not ref.options:get('Only if Quick peek assist') then
                                menu_logic.set(ref.hotkey, true)
                            end

                            if ref.options:get('Visualize') then
                                menu_logic.set(ref.color, true)
                            end
                        end
                    end

                    local is_air_auto_stop = ref.air_auto_stop.checkbox:get() do
                        local ref = other.rage.air_auto_stop
                        menu_logic.set(ref.checkbox, true)

                        if is_air_auto_stop then
                            menu_logic.set(ref.addons, true)

                            menu_logic.set(ref.hitchance, true)
                            menu_logic.set(ref.hitchance_label, true)

                            menu_logic.set(ref.distance, true)
                            menu_logic.set(ref.distance_label, true)

                            menu_logic.set(ref.separator, true)

                            if ref.addons:get('Work if speed lower than X') then
                                menu_logic.set(ref.speed, true)
                                menu_logic.set(ref.speed_label, true)
                            end
                        end
                    end

                    local is_auto_osaa = ref.auto_osaa.checkbox:get() do
                        local ref = other.rage.auto_osaa
                        menu_logic.set(ref.checkbox, true)

                        if is_auto_osaa then
                            menu_logic.set(ref.weapon, true)
                            menu_logic.set(ref.state_label, true)
                            menu_logic.set(ref.state, true)
                            menu_logic.set(ref.separator, true)
                        end
                    end

                    local is_auto_discharge = ref.auto_discharge.checkbox:get() do
                        local ref = other.rage.auto_discharge
                        menu_logic.set(ref.checkbox, true)

                        if is_auto_discharge then
                            menu_logic.set(ref.mode, true)
                            menu_logic.set(ref.hotkey, true)
                            menu_logic.set(ref.separator, true)

                            if ref.mode:get() == 'Air lag' then
                                menu_logic.set(ref.tick_label, true)
                                menu_logic.set(ref.tick, true)
                            end
                        end
                    end

                    local is_aimbot_helper = ref.aimbot_helper.checkbox:get() do
                        menu_logic.set(ref.aimbot_helper.checkbox, true)

                        if is_aimbot_helper then
                            local weapon = ref.aimbot_helper.weapons:get()
                            menu_logic.set(ref.aimbot_helper.weapons, true)

                            local items = ref.aimbot_helper[weapon]

                            if items ~= nil then
                                menu_logic.set(items.options_label, true)
                                menu_logic.set(items.options, true)

                                if items.options:get 'Force safe point' then
                                    menu_logic.set(items.force_safe_point.triggers_label, true)
                                    menu_logic.set(items.force_safe_point.triggers, true)

                                    if items.force_safe_point.triggers:get 'Enemy HP < X' then
                                        menu_logic.set(items.force_safe_point.hp_label, true)
                                        menu_logic.set(items.force_safe_point.hp, true)
                                    end

                                    if items.force_safe_point.triggers:get 'X missed shots' then
                                        menu_logic.set(items.force_safe_point.missed_shots_label, true)
                                        menu_logic.set(items.force_safe_point.missed_shots, true)
                                    end
                                end

                                if items.options:get 'Prefer body aim' then
                                    menu_logic.set(items.prefer_body_aim.triggers_label, true)
                                    menu_logic.set(items.prefer_body_aim.triggers, true)

                                    if items.prefer_body_aim.triggers:get 'Enemy HP < X' then
                                        menu_logic.set(items.prefer_body_aim.hp_label, true)
                                        menu_logic.set(items.prefer_body_aim.hp, true)
                                    end

                                    if items.prefer_body_aim.triggers:get 'X missed shots' then
                                        menu_logic.set(items.prefer_body_aim.missed_shots_label, true)
                                        menu_logic.set(items.prefer_body_aim.missed_shots, true)
                                    end
                                end

                                if items.options:get 'Force body aim' then
                                    menu_logic.set(items.force_body_aim.triggers_label, true)
                                    menu_logic.set(items.force_body_aim.triggers, true)

                                    if items.force_body_aim.triggers:get 'Enemy HP < X' then
                                        menu_logic.set(items.force_body_aim.hp_label, true)
                                        menu_logic.set(items.force_body_aim.hp, true)
                                    end

                                    if items.force_body_aim.triggers:get 'X missed shots' then
                                        menu_logic.set(items.force_body_aim.missed_shots_label, true)
                                        menu_logic.set(items.force_body_aim.missed_shots, true)
                                    end
                                end

                                if items.options:get 'Ping spike' then
                                    menu_logic.set(items.ping_spike.value_label, true)
                                    menu_logic.set(items.ping_spike.value, true)
                                end
                            end
                        end
                    end

                    local is_predict_enemies = ref.predict_enemies.checkbox:get() do
                        local ref = other.rage.predict_enemies
                        menu_logic.set(ref.checkbox, true)

                        if is_predict_enemies then
                            menu_logic.set(ref.hotkey, true)
                        end
                    end

                    local is_hitchance = ref.hitchance.checkbox:get() do
                        menu_logic.set(ref.hitchance.checkbox, true)

                        if is_hitchance then
                            local weapon = ref.hitchance.weapon:get()
                            menu_logic.set(ref.hitchance.weapon, true)

                            local items = ref.hitchance[weapon]

                            if items ~= nil then
                                local options = items.options:get()
                                menu_logic.set(items.options_label, true)
                                menu_logic.set(items.options, true)


                                for i = 1, #options do
                                    local option = options[i]
                                    local option_items = items[option]

                                    if option_items ~= nil then
                                        menu_logic.set(option_items.value_label, true)
                                        menu_logic.set(option_items.value, true)

                                        if option_items.distance ~= nil then
                                            menu_logic.set(option_items.distance_label, true)
                                            menu_logic.set(option_items.distance, true)
                                        end
                                    end
                                end

                                if items.options:get 'Hotkey' then
                                    menu_logic.set(ref.hitchance.hotkey, true)
                                    menu_logic.set(ref.hitchance.indicator_text, true)
                                end
                            end
                        end
                    end

                    menu_logic.set(ref.unsafe_exploit, true)
                    menu_logic.set(ref.disable_hold_tick, true)
                end

                if home_other == 'Miscellaneous' then
                    local ref = other.miscellaneous

                    menu_logic.set(ref.clantag, true)
                    menu_logic.set(ref.enemy_chat_viewer, true)
                    menu_logic.set(ref.item_crash_fix, true)
                    menu_logic.set(ref.allow_duck_on_fd, true)
                    menu_logic.set(ref.console_filter, true)
                    menu_logic.set(ref.fast_ladder, true)

                    local is_trash_talk = ref.trash_talk.checkbox:get() do
                        local ref = other.miscellaneous.trash_talk

                        menu_logic.set(ref.checkbox, true)

                        if is_trash_talk then
                            menu_logic.set(ref.type, true)
                            menu_logic.set(ref.events_label, true)
                            menu_logic.set(ref.events, true)
                        end
                    end

                    local is_game_enhancer = ref.game_enhancer.checkbox:get() do
                        local ref = other.miscellaneous.game_enhancer

                        menu_logic.set(ref.checkbox, true)

                        if is_game_enhancer then
                            menu_logic.set(ref.list, true)
                            menu_logic.set(ref.separator, true)
                        end
                    end

                    local is_animations = ref.animations.checkbox:get() do
                        local ref = other.miscellaneous.animations

                        menu_logic.set(ref.checkbox, true)

                        if is_animations then
                            menu_logic.set(ref.conditions, true)

                            if ref.conditions:get() == 'Moving' then
                                menu_logic.set(ref.moving.type_label, true)
                                menu_logic.set(ref.moving.type, true)
                                menu_logic.set(ref.moving.options_label, true)
                                menu_logic.set(ref.moving.options, true)

                                if ref.moving.options:get('Body Lean') then
                                    menu_logic.set(ref.moving.body_lean_label, true)
                                    menu_logic.set(ref.moving.body_lean, true)
                                end

                                if ref.moving.type:get() == 'Jitter' then
                                    menu_logic.set(ref.moving.min_jitter_label, true)
                                    menu_logic.set(ref.moving.min_jitter, true)
                                    menu_logic.set(ref.moving.max_jitter_label, true)
                                    menu_logic.set(ref.moving.max_jitter, true)
                                end
                            end

                            if ref.conditions:get() == 'In Air' then
                                menu_logic.set(ref.air.type_label, true)
                                menu_logic.set(ref.air.type, true)
                                menu_logic.set(ref.air.options_label, true)
                                menu_logic.set(ref.air.options, true)

                                if ref.air.options:get('Body Lean') then
                                    menu_logic.set(ref.air.body_lean_label, true)
                                    menu_logic.set(ref.air.body_lean, true)
                                end

                                if ref.air.type:get() == 'Jitter' then
                                    menu_logic.set(ref.air.min_jitter_label, true)
                                    menu_logic.set(ref.air.min_jitter, true)
                                    menu_logic.set(ref.air.max_jitter_label, true)
                                    menu_logic.set(ref.air.max_jitter, true)
                                end
                            end
                            -- menu_logic.set(ref.list, true)
                            -- menu_logic.set(ref.separator, true)
                        end
                    end


                    local is_drop_nades = ref.drop_nades.checkbox:get() do
                        local ref = other.miscellaneous.drop_nades

                        menu_logic.set(ref.checkbox, true)

                        if is_drop_nades then
                            menu_logic.set(ref.grenades_label, true)
                            menu_logic.set(ref.hotkey, true)
                            menu_logic.set(ref.grenades, true)
                            menu_logic.set(ref.separator, true)
                        end
                    end

                    local is_edge_quick_stop = ref.edge_quick_stop.checkbox:get() do
                        local ref = other.miscellaneous.edge_quick_stop

                        menu_logic.set(ref.checkbox, true)

                        if is_edge_quick_stop then
                            menu_logic.set(ref.hotkey, true)
                        end
                    end

                    local is_automatic_purchase = ref.automatic_purchase.checkbox:get() do
                        local ref = other.miscellaneous.automatic_purchase

                        menu_logic.set(ref.checkbox, true)

                        if is_automatic_purchase then
                            menu_logic.set(ref.primary, true)
                            menu_logic.set(ref.secondary_label, true)
                            menu_logic.set(ref.secondary, true)
                            menu_logic.set(ref.equipment_label, true)
                            menu_logic.set(ref.equipment, true)
                            menu_logic.set(ref.options_label, true)
                            menu_logic.set(ref.options, true)

                            if ref.primary:get() == 'AWP' then
                                menu_logic.set(ref.alternative_label, true)
                                menu_logic.set(ref.alternative, true)
                            end
                        end
                    end
                end
            end

            if category == 'Anti-Aim' then
                local ref = antiaim.selector

                menu_logic.set(ref.separator, true)
                menu_logic.set(ref.tab_label, true)
                menu_logic.set(ref.tab, true)
                menu_logic.set(ref.separator2, true)

                if home_antiaim == 'Builder' then
                    local builder do
                        local ref = antiaim.builder

                        local state = ref.state:get()
                        menu_logic.set(ref.state_label, true)
                        menu_logic.set(ref.state, true)

                        local items = ref[state]

                        if items == nil then
                            goto continue
                        end

                        update_builder_items(items)

                        ::continue::
                    end
                end

                if home_antiaim == 'Features' then
                    local ref = antiaim.features

                    local is_avoid_backstab = ref.avoid_backstab.checkbox:get() do
                        local ref = antiaim.features.avoid_backstab
                        menu_logic.set(ref.checkbox, true)

                        if is_avoid_backstab then
                            menu_logic.set(ref.distance, true)
                            menu_logic.set(ref.separator, true)
                        end
                    end

                    menu_logic.set(ref.vanish, true)

                    local is_break_lc_triggers = ref.break_lc_triggers.checkbox:get() do
                        local ref = antiaim.features.break_lc_triggers
                        menu_logic.set(ref.checkbox, true)

                        if is_break_lc_triggers then
                            menu_logic.set(ref.states, true)
                            menu_logic.set(ref.separator, true)
                        end
                    end

                    local is_safe_head = ref.safe_head.checkbox:get() do
                        local ref = antiaim.features.safe_head
                        menu_logic.set(ref.checkbox, true)

                        if is_safe_head then
                            menu_logic.set(ref.conditions, true)
                            menu_logic.set(ref.options_label, true)
                            menu_logic.set(ref.options, true)
                        end
                    end

                    local is_manual_yaw = ref.manual_yaw.checkbox:get() do
                        local ref = antiaim.features.manual_yaw
                        menu_logic.set(ref.checkbox, true)

                        if is_manual_yaw then
                            menu_logic.set(ref.options, true)
                            menu_logic.set(ref.left_label, true)
                            menu_logic.set(ref.left, true)
                            menu_logic.set(ref.right_label, true)
                            menu_logic.set(ref.right, true)
                            menu_logic.set(ref.forward_label, true)
                            menu_logic.set(ref.forward, true)
                            menu_logic.set(ref.reset_label, true)
                            menu_logic.set(ref.reset, true)

                            menu_logic.set(ref.separator, true)
                        end
                    end

                    local is_freestanding = ref.freestanding.checkbox:get() do
                        local ref = antiaim.features.freestanding
                        menu_logic.set(ref.checkbox, true)

                        if is_freestanding then
                            menu_logic.set(ref.hotkey, true)
                            menu_logic.set(ref.disablers, true)

                            menu_logic.set(ref.separator, true)
                        end
                    end

                    local is_edge_yaw = ref.edge_yaw.checkbox:get() do
                        local ref = antiaim.features.edge_yaw
                        menu_logic.set(ref.checkbox, true)

                        if is_edge_yaw then
                            menu_logic.set(ref.hotkey, true)
                            menu_logic.set(ref.disablers, true)

                            menu_logic.set(ref.separator, true)
                        end
                    end

                    local is_fakelag = ref.fakelag.checkbox:get() do
                        local ref = antiaim.features.fakelag
                        menu_logic.set(ref.checkbox, true)

                        if is_fakelag then
                            menu_logic.set(ref.hotkey, true)
                            menu_logic.set(ref.type, true)
                            menu_logic.set(ref.variance, true)
                            menu_logic.set(ref.variance_label, true)
                            menu_logic.set(ref.limit, true)
                            menu_logic.set(ref.limit_label, true)

                            menu_logic.set(ref.separator, true)
                        end
                    end

                    local is_slow_motion = ref.slow_motion.checkbox:get() do
                        local ref = antiaim.features.slow_motion
                        menu_logic.set(ref.checkbox, true)

                        if is_slow_motion then
                            menu_logic.set(ref.hotkey, true)
                        end
                    end

                    local is_osaa = ref.osaa.checkbox:get() do
                        local ref = antiaim.features.osaa
                        menu_logic.set(ref.checkbox, true)

                        if is_osaa then
                            menu_logic.set(ref.hotkey, true)
                        end
                    end

                    local is_fake_peek = ref.fake_peek.checkbox:get() do
                        local ref = antiaim.features.fake_peek
                        menu_logic.set(ref.checkbox, true)

                        if is_fake_peek then
                            menu_logic.set(ref.hotkey, true)
                        end
                    end
                end
            end
        end

        local function on_shutdown()
            set_antiaimbot_display(true)
            set_fakelag_display(true)
            set_other_display(true)
        end

        local function on_paint_ui()
            set_antiaimbot_display(false)
            set_fakelag_display(false)
            set_other_display(false)
        end

        local logic_events = menu_logic.get_event_bus() do
            logic_events.update:set(force_update_scene)

            force_update_scene()
            menu_logic.force_update()
        end

        client.set_event_callback('shutdown', on_shutdown)
        client.set_event_callback('paint_ui', on_paint_ui)
    end
end

local config = { } do
    local ref = menu_elements.home.config_local

    local DB_NAME = '##EMBERLASH_DB'
    local DB_DEFAULT = { }

    local db_data = (
        localdb['config']
        or database.read(DB_NAME)
        or DB_DEFAULT
    )

    local config_data = { }
    local config_list = { }

    local config_defaults = {
        [1] = {
            name = 'Default',
            data = 'emberlash_133sqtr32==_',
            author = 'Iska',
            date = '01.07.2025'
        }
    }

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
        config_data[i] = db_data[i]

        if config_data[i].author == nil then
            config_data[i].author = "Unknown"
        end

        if config_data[i].date == nil then
            config_data[i].date = "Unknown"
        end
    end

    for i = #config_defaults, 1, -1 do
        local list = config_defaults[i]

        if list.data == nil then
            goto continue
        end

        local ok, result = config_system.decode(list.data)

        if not ok then
            -- config is not valid, delete it
            table.remove(config_defaults, i)
            goto continue
        end

        list.data = result

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
        for i = 1, #config_list do
            local data = config_list[i]

            if data.name == name then
                return data, i
            end
        end

        return nil, -1
    end

    local function save_config_data()
        localdb['config'] = config_data
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

        update_config_info_ui(list)
    end

    local function save_config(name)
        --windows.save_settings()

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

            logging.success(string.format(
                'created %s config', name
            ))

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

        logging.success(string.format(
            'saved %s config', name
        ))
    end

    local function delete_config(name)
        local list, idx = find_config(name)

        if list == nil or idx == -1 then
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

        local next_input = ''

        local index = math.min(
            ref.list:get() + 1,
            #config_list
        )

        local data = config_list[index]

        if data ~= nil then
            next_input = data.name
        end

        ref.input:set(next_input)

        logging.success(string.format(
            'deleted %s config', name
        ))

        clear_config_info_ui()
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
            --windows.save_settings()

            local ok, result = config_system.encode(
                config_system.export()
            )

            if not ok then
                return
            end

            clipboard.set(result)

            logging.success(
                'exported config with metadata'
            )
        end

        local function on_import()
            local str = clipboard.get()

            if str == nil then
                return
            end

            local ok, result = config_system.decode(str)

            if not ok then
                return
            end

            config_system.import(result)

            --windows.load_settings()

            logging.success(
                'imported config'
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

    clear_config_info_ui()
end

local rage do
    local air_auto_stop = { } do
        local ref = menu_elements.other.rage.air_auto_stop

        local delay_ticks = 13
        local last_air_tick = 0

        local speed_limit = ref.speed:get()

        local function can_shoot(me, gun)
            if not me or not gun then
                return false
            end

            local next_attack = entity.get_prop(me, 'm_flNextAttack') or 0
            local next_primary = entity.get_prop(gun, 'm_flNextPrimaryAttack') or 0
            local curtime = globals.curtime()
            local clip = entity.get_prop(gun, 'm_iClip1') or 0

            return (math.max(next_attack, next_primary) <= curtime) and clip > 0
        end

        local function is_enemy_visible(local_player, enemy)
            local local_player_origin = {entity.get_origin(local_player)}
            local enemy_origin = {entity.get_origin(enemy)}

            if local_player_origin[1] == nil or enemy_origin[1] == nil then
                return false
            end

            local trace_fraction = client.trace_bullet(
                local_player,
                local_player_origin[1],
                local_player_origin[2],
                local_player_origin[3] + 16,
                enemy_origin[1],
                enemy_origin[2],
                enemy_origin[3] + 16
            )

            return trace_fraction
        end

        local function estimate_hitchance(me, gun)
            local weapon_class = entity.get_classname(gun)

            if weapon_class ~= 'CWeaponSSG08' then
                return 0
            end

            local scoped = entity.get_prop(me, 'm_bIsScoped') == 1
            local duck = entity.get_prop(me, 'm_flDuckAmount') or 0
            local velocity = vector(entity.get_prop(me, 'm_vecVelocity'))
            local speed = velocity:length2d()
            local dist = 0
            local threat = client.current_threat()

            if threat then
                local my_pos = vector(entity.get_origin(me))
                local enemy_pos = vector(entity.get_origin(threat))
                dist = my_pos:dist(enemy_pos)
            end

            local base_spread = 0.002
            if not scoped then
                base_spread = 0.08
            end

            if duck == 1 then
                base_spread = base_spread * 0.7
            end

            if speed > 5 then
                base_spread = base_spread + (speed / 300) * 0.08
            end

            if dist > 1000 then
                base_spread = base_spread + (dist - 1000) / 4000
            end

            local hc = 100 - (base_spread * 1000)

            if hc > 100 then
                hc = 100
            end

            if hc < 0 then
                hc = 0
            end

            return hc
        end

        local function angle_math(x, y)
            local angle_x_sin = math.sin(math.rad(x))
            local angle_x_cos = math.cos(math.rad(x))
            local angle_y_sin = math.sin(math.rad(y))
            local angle_y_cos = math.cos(math.rad(y))
            return angle_x_cos * angle_y_cos, angle_x_cos * angle_y_sin, -angle_x_sin
        end

        local function on_setup_command(e)
            local me = entity.get_local_player()
            if not me or not entity.is_alive(me) then
                last_air_tick = 0
                return
            end

            local gun = entity.get_player_weapon(me)

            local tick = globals.tickcount()
            if not is_on_ground then
                if last_air_tick == 0 then
                    last_air_tick = tick
                end
            else
                last_air_tick = 0
                return
            end

            if tick - last_air_tick < delay_ticks then
                return
            end

            if not can_shoot(me, gun) then
                return
            end

            local can_work = false

            if ref.addons:get 'Only if quick peek assist' then
                can_work = reference.is_quick_peek_assist()
            else
                can_work = true
            end

            local local_team = entity.get_prop(me, 'm_iTeamNum')
            local enemies = entity.get_players(true)

            for i = 1, #enemies do
                local enemy = enemies[i]

                if entity.get_prop(enemy, 'm_iTeamNum') ~= local_team and entity.is_alive(enemy) then
                    if is_enemy_visible(me, enemy) then
                        local hc = estimate_hitchance(me, gun)

                        local my_origin = vector(
                            entity.get_origin(me)
                        )

                        local threat_origin = vector(
                            entity.get_origin(enemy)
                        )

                        local delta = threat_origin - my_origin

                        local distancesqr = delta:length2dsqr()

                        local height = -delta.z

                        if is_dormant then
                            return
                        end

                        if distancesqr > ref.distance:get() * 1000 then
                            return
                        end

                        if hc < ref.hitchance:get() then
                            return
                        end

                        if not can_work then
                            return
                        end

                        if ref.addons:get 'Only if quick peek assist' then
                            if reference.is_quick_peek_assist() and distancesqr < 70000 and height <= 190 then
                                e.quick_stop = true
                            end
                        end

                        local velocity = vector(entity.get_prop(me, 'm_vecVelocity'))
                        local speed = velocity:length2d()

                        if ref.addons:get 'Work if speed lower than X' and (speed < speed_limit) then
                            return
                        end

                        local velocity_angles = vector(velocity:angles())
                        local camera_angles = vector(client.camera_angles())

                        velocity_angles.y = camera_angles.y - velocity_angles.y
                        local calc_x, calc_y = angle_math(velocity_angles.x, velocity_angles.y)

                        local sidespeed = -cvar.cl_sidespeed:get_float()
                        local final_x = sidespeed * calc_x
                        local final_y = sidespeed * calc_y

                        e.in_speed = -1
                        e.forwardmove = final_x
                        e.sidemove = final_y
                        break
                    end
                end
            end
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if not value then
                    return
                end

                utils.event_callback(
                    'setup_command',
                    on_setup_command,
                    value
                )
            end

            ref.checkbox:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local auto_on_shot_antiaim = { } do
        local ref = menu_elements.other.rage.auto_osaa

        local ref_duck_peek_assist = ui.reference(
            'Rage', 'Other', 'Duck peek assist'
        )

        local ref_quick_peek_assist = {
            ui.reference('Rage', 'Other', 'Quick peek assist')
        }

        local ref_double_tap = {
            ui.reference('Rage', 'Aimbot', 'Double tap')
        }

        local ref_on_shot_antiaim = {
            ui.reference('AA', 'Other', 'On shot anti-aim')
        }

        local function get_state()
            if not localplayer.is_onground then
                if localplayer.is_crouched then
                    return 'Air & Crouched'
                end

                return 'Air'
            end

            if localplayer.is_crouched then
                if localplayer.is_moving then
                    return 'Crouching & Move'
                end

                return 'Crouching'
            end

            if localplayer.is_moving then
                if reference.is_slow_motion() then
                    return 'Slow Walk'
                end

                return 'Moving'
            end

            return 'Standing'
        end

        local function get_weapon_type(weapon)
            local weapon_info = csgo_weapons(weapon)

            if weapon_info == nil then
                return nil
            end

            local weapon_type = weapon_info.type
            local weapon_index = weapon_info.idx

            if weapon_type == 'smg' then
                return 'SMG'
            end

            if weapon_type == 'rifle' then
                return 'Rifles'
            end

            if weapon_type == 'pistol' then
                if weapon_index == 1 then
                    return 'Desert Eagle'
                end

                if weapon_index == 64 then
                    return 'R8 Revolver'
                end

                return 'Pistols'
            end

            if weapon_type == 'sniperrifle' then
                if weapon_index == 40 then
                    return 'Scout'
                end

                if weapon_index == 9 then
                    return 'AWP'
                end

                return 'Auto Snipers'
            end

            return nil
        end

        local function update_values()
            ragebot.set(ref_double_tap[1], false)

            override.set(ref_on_shot_antiaim[1], true)
            override.set(ref_on_shot_antiaim[2], 'Always on')
        end

        local function should_update()
            if ui.get(ref_duck_peek_assist) then
                return false
            end

            local is_quick_peek_assist = (
                ui.get(ref_quick_peek_assist[1]) and
                ui.get(ref_quick_peek_assist[2])
            )

            if is_quick_peek_assist then
                return false
            end

            if not ui.get(ref_double_tap[2]) then
                return false
            end

            local me = entity.get_local_player()

            if me == nil then
                return false
            end

            local weapon = entity.get_player_weapon(me)

            if weapon == nil then
                return false
            end

            local weapon_type = get_weapon_type(weapon)

            if weapon_type == nil or not ref.weapon:get(weapon_type) then
                return false
            end

            local state = get_state()

            if not ref.state:get(state) then
                return false
            end

            return true
        end

        function auto_on_shot_antiaim:update(cmd)
            if not ref.checkbox:get() then
                return false
            end

            if not should_update() then
                return false
            end

            update_values()
            return true
        end
    end

    local auto_discharge = { } do
        local ref = menu_elements.other.rage.auto_discharge

        local ref_enabled = {
            ui.reference('Rage', 'Aimbot', 'Enabled')
        }

        local ref_double_tap = {
            ui.reference('Rage', 'Aimbot', 'Double tap')
        }

        local delay_ticks = 0

        local function update_default()
            if localplayer.is_vulnerable then
                ragebot.set(ref_double_tap[1], false)

                return true
            end

            return false
        end

        local function update_air_lag()
            local delay = ref.tick:get() + 3
            delay_ticks = delay_ticks + 1

            if delay_ticks >= delay then
                delay_ticks = 0

                ragebot.set(ref_double_tap[1], false)
            end

            ragebot.set(ref_enabled[1], false)

            return true
        end

        function auto_discharge:update(cmd)
            if not ref.checkbox:get() then
                return
            end

            if not ref.hotkey:get() then
                return
            end

            local value = ref.mode:get()

            if value == 'Default' then
                update_default()
            end

            if value == 'Air lag' then
                update_air_lag()
            end
        end
    end

    local unsafe_exploit_recharge = { } do
        local ref = menu_elements.other.rage.unsafe_exploit

        local prev_state = false

        local ref_enabled = {
            ui.reference('Rage', 'Aimbot', 'Enabled')
        }

        local ref_double_tap = {
            ui.reference('Rage', 'Aimbot', 'Double tap')
        }

        local ref_on_shot_antiaim = {
            ui.reference('AA', 'Other', 'On shot anti-aim')
        }

        local ref_duck_peek_assist = ui.reference(
            'Rage', 'Other', 'Duck peek assist'
        )

        local function is_double_tap_active()
            return ui.get(ref_double_tap[1])
                and ui.get(ref_double_tap[2])
        end

        local function is_on_shot_antiaim_active()
            return ui.get(ref_on_shot_antiaim[1])
                and ui.get(ref_on_shot_antiaim[2])
        end

        local function is_tickbase_changed(player)
            return (globals.tickcount() - entity.get_prop(player, 'm_nTickBase')) > 0
        end

        local function should_change(me, weapon)
            local weapon_info = csgo_weapons(weapon)

            if weapon_info == nil then
                return false
            end

            local threat = client.current_threat()

            if threat == nil then
                return false
            end

            local esp_data = entity.get_esp_data(threat)

            if esp_data == nil then
                return false
            end

            local esp_flags = esp_data.flags

            if esp_flags == nil then
                return false
            end

            if bit.band(esp_flags, 2048) == 0 then
                return false
            end

            if ui.get(ref_duck_peek_assist) then
                return false
            end

            local state = is_double_tap_active()
            local charged = exploit.get().shift

            if prev_state ~= state then
                if state and not charged then
                    return true
                end

                prev_state = state
            end

            if is_on_shot_antiaim_active() then
                return not is_tickbase_changed(me)
            end

            return false
        end


        function unsafe_exploit_recharge:update(cmd)
            if not ref:get() then
                return
            end

            local me = entity.get_local_player()

            if me == nil then
                return false
            end

            local weapon = entity.get_player_weapon(me)

            if weapon == nil then
                return false
            end

            if not should_change(me, weapon) then
                return
            end

            ragebot.set(ref_enabled[1], false)
        end
    end

    local predict_enemies = { } do
        local ref = menu_elements.other.rage.predict_enemies

        local cl_interpolate = cvar.cl_interpolate
        local cl_interp_ratio = cvar.cl_interp_ratio

        local function restore_value()
            cl_interpolate:set_int(
                tonumber(cl_interpolate:get_string()) or 0
            )

            cl_interp_ratio:set_int(
                tonumber(cl_interp_ratio:get_string()) or 0
            )

        end

        local function on_shutdown()
            restore_value()
        end

        local function on_paint_ui()
            if not ref.hotkey:get() then
                return
            end

            cl_interp_ratio:set_int(2)
            cl_interpolate:set_int(1)
        end

        local function on_pre_render()
            if not ref.hotkey:get() then
                return
            end

            cl_interpolate:set_int(0)
            cl_interp_ratio:set_int(1)
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if not value then
                    restore_value()
                end

                restore_value()

                utils.event_callback(
                    'shutdown',
                    on_shutdown,
                    value
                )

                utils.event_callback(
                    'pre_render',
                    on_pre_render,
                    value
                )

                utils.event_callback(
                    'paint_ui',
                    on_paint_ui,
                    value
                )
            end

            ref.checkbox:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local disable_hold_tick = { } do
        local ref = menu_elements.other.rage.disable_hold_tick

        local ref_fakelag_enabled = {
            ui.reference('AA', 'Fake lag', 'Enabled')
        }

        local ref_fakelag_amount = ui.reference(
            'AA', 'Fake lag', 'Amount'
        )

        local function get_state()
            local is_fakelag =
                not reference.is_double_tap_active() and
                not reference.is_on_shot_antiaim_active()

            local is_breaklc = exploit.get().breaking_lc

            if is_breaklc then
                return 'Break LC'
            end

            if not localplayer.is_onground then
                if localplayer.is_crouched then
                    return 'Air & Crouched'
                end

                return 'Air'
            end

            if localplayer.is_crouched then
                if localplayer.is_moving then
                    return 'Crouching & Move'
                end

                return 'Crouching'
            end

            if localplayer.is_moving then
                return 'Moving'
            end

            if is_fakelag then
                return 'Fake Lag'
            end

            return 'Standing'
        end

        local function restore_values()
            override.unset(ref_fakelag_enabled[1])
            override.unset(ref_fakelag_enabled[2])
            override.unset(ref_fakelag_amount)
        end

        local function update_values()
            local me = entity.get_local_player()

            if me == nil then
                return
            end

            if not entity.is_alive(me) then
                return
            end

            local state = get_state()

            override.set(ref_fakelag_enabled[1], true)
            override.set(ref_fakelag_enabled[2], 'Always on')

            if state == nil then
                override.set(ref_fakelag_amount, 'Fluctuate')
            end

            local is_max_fakelag =
                state == 'Break LC' or
                state == 'Air' or
                state == 'Air & Crouched'

            if is_max_fakelag then
                override.set(ref_fakelag_amount, 'Maximum')
            end

            local is_dynamic_fakelag =
                state == 'Standing' or
                state == 'Moving' or
                state == 'Crouching' or
                state == 'Crouching & Move'

            if is_dynamic_fakelag then
                override.set(ref_fakelag_amount, 'Dynamic')
            end
        end

        local function on_shutdown()
            restore_values()
        end

        local function on_setup_command()
            update_values()
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if not value then
                    restore_values()
                end

                utils.event_callback(
                    'shutdown',
                    on_shutdown,
                    value
                )

                utils.event_callback(
                    'setup_command',
                    on_setup_command,
                    value
                )
            end

            ref:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local hitchance_override = { } do
        local ref = menu_elements.other.rage.hitchance

        local UNITS_TO_FOOT = 0.0254 * 3.28084

        local ref_hit_chance = ui.reference(
            'Rage', 'Aimbot', 'Minimum hit chance'
        )

        local data_table = {
            updated_hotkey = false,
            updated_this_tick = false
        }

        local function get_distance(player, target)
            if player == nil or target == nil then
                return nil
            end

            local player_origin = vector(entity.get_origin(player))
            local target_origin = vector(entity.get_origin(target))

            return (target_origin - player_origin):length()
        end

        local function get_value(me, weapon_type, items)
            local threat = client.current_threat()

            if items.options:get 'Hotkey' and ref.hotkey:get() then
                data_table.updated_hotkey = true
                return items['Hotkey'].value:get()
            end

            if items.options:get 'No Scope' then
                local goal_distance = items['No Scope'].distance:get()
                local hitchance_value = items['No Scope'].value:get()

                if goal_distance == 101 then
                    return hitchance_value
                end

                local distance = get_distance(me, threat)

                if distance ~= nil and (distance * UNITS_TO_FOOT) <= goal_distance then
                    return hitchance_value
                end
            end

            if items.options:get 'In Air' and not localplayer.is_onground then
                return items['In Air'].value:get()
            end
        end

        local function get_weapon_type(weapon)
            local weapon_info = csgo_weapons(weapon)

            if weapon_info == nil then
                return nil
            end

            local weapon_type = weapon_info.type
            local weapon_index = weapon_info.idx

            if weapon_type == 'pistol' then
                if weapon_index == 1 then
                    return 'Desert Eagle'
                end

                if weapon_index == 64 then
                    return 'R8 Revolver'
                end

                return 'Pistols'
            end

            if weapon_type == 'sniperrifle' then
                if weapon_index == 40 then
                    return 'Scout'
                end

                if weapon_index == 9 then
                    return 'AWP'
                end

                return 'Auto Snipers'
            end

            return nil
        end

        local function update_hitchance()
            local me = entity.get_local_player()

            if me == nil then
                return
            end

            local weapon = entity.get_player_weapon(me)

            if weapon == nil then
                return
            end

            local weapon_type = get_weapon_type(weapon)

            if weapon_type == nil then
                return
            end

            local items = ref[weapon_type]

            if items == nil then
                return
            end

            local value = get_value(
                me, weapon_type, items
            )

            if value == nil then
                return
            end

            ragebot.set(ref_hit_chance, value)
            data_table.updated_this_tick = true
        end

        local function on_shutdown()
            ragebot.unset(ref_hit_chance)
        end

        local function on_run_command()
            data_table.updated_hotkey = false
            data_table.updated_this_tick = false

            update_hitchance()
        end

        local function on_finish_command()
            ragebot.unset(ref_hit_chance)
        end

        local function on_paint()
            local me = entity.get_local_player()

            if me == nil or not entity.is_alive(me) then
                return
            end

            local should_render = (
                data_table.updated_hotkey and
                data_table.updated_this_tick
            )

            if not should_render then
                return
            end

            local text = 'HC'

            if text == 'Off' then
                return
            end

            renderer.indicator(255, 255, 255, 200, text)
        end

        local function on_pre_config_save()
            ragebot.unset(ref_hit_chance)
        end

        local callbacks do
            local function on_enabled(item)
                local value = item:get()

                if not value then
                    ragebot.unset(ref_hit_chance)
                end

                utils.event_callback(
                    'shutdown',
                    on_shutdown,
                    value
                )

                utils.event_callback(
                    'run_command',
                    on_run_command,
                    value
                )

                utils.event_callback(
                    'finish_command',
                    on_finish_command,
                    value
                )

                utils.event_callback(
                    'paint',
                    on_paint,
                    value
                )

                utils.event_callback(
                    'pre_config_save',
                    on_pre_config_save,
                    value
                )
            end

            ref.checkbox:set_callback(
                on_enabled, true
            )
        end
    end

    local aimbot_helper = { } do
        local ref = menu_elements.other.rage.aimbot_helper

        local ref_ping_spike = {
            ui.reference('Misc', 'Miscellaneous', 'Ping spike')
        }

        local player_data = { }

        local manipulation do
            manipulation = { }

            local item_data = { }

            function manipulation.set(entindex, item_name, ...)
                if item_data[entindex] == nil then
                    item_data[entindex] = { }
                end

                if item_data[entindex][item_name] == nil then
                    item_data[entindex][item_name] = {
                        plist.get(entindex, item_name)
                    }
                end

                plist.set(entindex, item_name, ...)
            end

            function manipulation.unset(entindex, item_name)
                local entity_data = item_data[entindex]

                if entity_data == nil then
                    return
                end

                local item_values = entity_data[item_name]

                if item_values == nil then
                    return
                end

                plist.set(entindex, item_name, unpack(item_values))

                entity_data[item_name] = nil
            end

            function manipulation.override(entindex, item_name, ...)
                if ... ~= nil then
                    manipulation.set(entindex, item_name, ...)
                else
                    manipulation.unset(entindex, item_name)
                end
            end
        end

        local function is_triggered(items, context)
            if items == nil then
                return false
            end

            if items.triggers:get 'Enemy HP < X' then
                if context.health < items.hp:get() then
                    return true
                end
            end

            if items.triggers:get 'X missed shots' then
                if context.misses > items.missed_shots:get() then
                    return true
                end
            end

            if items.triggers:get 'Lethal' then
                if context.health <= 30 then
                    return true
                end
            end

            if items.triggers:get 'Height advantage' then
                if context.height > 70 then
                    return true
                end
            end

            if items.triggers:get 'Enemy higher than you' then
                if context.height < -70 then
                    return true
                end
            end

            return false
        end

        local function delete_player_data(player)
            player_data[player] = nil
        end

        local function clear_player_data()
            for k in pairs(player_data) do
                delete_player_data(k)
            end
        end

        local function create_player_data()
            local data = {
                misses = 0
            }

            return data
        end

        local function get_player_data(player, create_if_absent)
            if create_if_absent and player_data[player] == nil then
                player_data[player] = create_player_data()
            end

            return player_data[player]
        end

        local function get_weapon_type(weapon)
            local weapon_info = csgo_weapons(weapon)

            if weapon_info == nil then
                return nil
            end

            local weapon_type = weapon_info.type
            local weapon_index = weapon_info.idx

            if weapon_type == 'sniperrifle' then
                if weapon_index == 40 then
                    return 'Scout'
                end

                if weapon_index == 9 then
                    return 'AWP'
                end

                return 'Auto Snipers'
            end

            if weapon_type == 'pistol' then
                if weapon_index == 1 then
                    return 'Desert Eagle'
                end

                if weapon_index == 64 then
                    return 'R8 Revolver'
                end

                return 'Pistols'
            end

            if weapon_type == 'shotgun' then
                return 'Shotgun'
            end

            if weapon_type == 'smg' then
                return 'SMG'
            end

            if weapon_type == 'machinegun' then
                return 'Machine gun'
            end

            return nil
        end

        local function get_height_advantage(player, target)
            local player_origin = vector(entity.get_origin(player))
            local target_origin = vector(entity.get_origin(target))

            return math.ceil(player_origin.z - target_origin.z)
        end

        local function get_player_context(me, enemy)
            local context = { }

            local data = get_player_data(enemy)

            context.health = entity.get_prop(enemy, 'm_iHealth')
            context.misses = data ~= nil and data.misses or 0
            context.height = get_height_advantage(me, enemy)

            return context
        end

        local function get_body_aim_value(items, context)
            local should_prefer = (
                items.options:get 'Prefer body aim'
                and is_triggered(items.prefer_body_aim, context)
            )

            local should_force = (
                items.options:get 'Force safe point'
                and is_triggered(items.force_body_aim, context)
            )

            if should_force then
                return 'Force'
            end

            if should_prefer then
                return 'On'
            end

            return nil
        end

        local function get_safe_point_value(items, context)
            local should_force = (
                items.options:get 'Force safe point'
                and is_triggered(items.force_safe_point, context)
            )

            if should_force then
                return 'On'
            end

            return nil
        end

        local function reset_aimbot_helper()
            local enemies = entity.get_players(true)

            for i = 1, #enemies do
                local enemy = enemies[i]

                manipulation.unset(enemy, 'Override safe point')
                manipulation.unset(enemy, 'Override prefer body aim')
            end

            override.unset(ref_ping_spike[3])
        end

        local function update_aimbot_helper()
            local me = entity.get_local_player()

            if me == nil then
                return false
            end

            local weapon = entity.get_player_weapon(me)

            if weapon == nil then
                return false
            end

            local weapon_type = get_weapon_type(weapon)

            if weapon_type == nil then
                return false
            end

            local items = ref[weapon_type]

            if items == nil then
                return false
            end

            local enemies = entity.get_players(true)

            for i = 1, #enemies do
                local enemy = enemies[i]

                local context = get_player_context(me, enemy)

                local safe_point = get_safe_point_value(items, context)
                local body_aim = get_body_aim_value(items, context)

                manipulation.override(enemy, 'Override safe point', safe_point)
                manipulation.override(enemy, 'Override prefer body aim', body_aim)
            end

            if items.options:get 'Ping spike' then
                override.set(ref_ping_spike[3], items.ping_spike.value:get())
            else
                override.unset(ref_ping_spike[3])
            end

            return true
        end

        local function on_shutdown()
            reset_aimbot_helper()
        end

        local function on_aim_miss(e)
            if e.reason == 'prediction error' then
                return
            end

            local target = e.target

            if target == nil then
                return
            end

            local info = get_player_data(target, true) do
                info.misses = info.misses + 1
            end
        end

        local function on_player_spawn(e)
            local userid = client.userid_to_entindex(e.userid)

            if userid == nil then
                return
            end

            delete_player_data(userid)
        end

        local function on_setup_command(cmd)
            if not update_aimbot_helper() then
                reset_aimbot_helper()
            end

            client.update_player_list()
        end

        local callbacks do
            local function on_enabled(item)
                local value = item:get()

                if not value then
                    clear_player_data()
                    reset_aimbot_helper()
                end

                utils.event_callback('shutdown', on_shutdown, value)
                utils.event_callback('aim_miss', on_aim_miss, value)
                utils.event_callback('player_spawn', on_player_spawn, value)
                utils.event_callback('setup_command', on_setup_command, value)
            end

            ref.checkbox:set_callback(
                on_enabled, true
            )
        end
    end

    local peek_bot = { } do
        local ref = menu_elements.other.rage.automatic_peek

        local hitgroups_to_hitboxes = {
            ['Head'] = {0},
            ['Chest'] = {4, 5, 6},
            ['Stomach'] = {2, 3},
            ['Arms'] = {13, 14, 15, 16, 17, 18},
            ['Legs'] = {7, 8, 9, 10},
            ['Feet'] = {11, 12}
        }

        local allowed_hitboxes = {0, 5, 2, 15, 17, 9, 10}
        local active_hitboxes = {}

        local amount = 4
        local step_distance = 22

        local targeting = false
        local returning = false
        local should_return = false
        local teleport = false
        local disable_exploit = false

        local cache = {
            positions = {},
            middle_pos = vector(),
            last_returning_time = 0,
            active_point_index = 0,
            current_target = nil
        }

        local hotkeys = {
            main = false,
            force_baim = false
        }

        local visual = {
            active = false,

            values = {
                global_alpha = 0,
                pos = { },
                alpha = { }
            }
        }

        local max_step = 18

        local scope_weapons = {
            'CWeaponSSG08',
            'CWeaponAWP',
            'CWeaponG3SG1',
            'CWeaponSCAR20'
        }

        local function extend_vector(pos, length, angle)
            local rad = angle * math.pi / 180
            return vector(
                pos.x + (math.cos(rad) * length),
                pos.y + (math.sin(rad) * length),
                pos.z
            )
        end

        local function extrapolate_position(ent, origin, ticks, inverted)
            local tickinterval = globals.tickinterval()

            local sv_gravity = cvar.sv_gravity:get_float() * tickinterval
            local sv_jump_impulse = cvar.sv_jump_impulse:get_float() * tickinterval

            local p_origin, prev_origin = origin, origin

            local velocity = vector(
                entity.get_prop(ent, 'm_vecVelocity')
            )

            local gravity = velocity.z > 0 and -sv_gravity or sv_jump_impulse

            for i = 1, ticks do
                prev_origin = p_origin
                p_origin = vector(
                    p_origin.x + (inverted and -(velocity.x * tickinterval) or (velocity.x * tickinterval)),
                    p_origin.y + (inverted and -(velocity.y * tickinterval) or (velocity.y * tickinterval)),
                    p_origin.z + (inverted and -((velocity.z + gravity) * tickinterval) or (velocity.z + gravity) * tickinterval)
                )

                local fraction = client.trace_line(-1,
                    prev_origin.x, prev_origin.y, prev_origin.x,
                    p_origin.x, p_origin.y, p_origin.x
                )

                if fraction <= .99 then
                    return prev_origin
                end
            end

            return p_origin
        end

        local function set_movement(cmd, destination, local_player)
            local move_yaw = vector(vector(entity.get_origin(local_player)):to(destination):angles()).y

            cmd.in_forward = 1
            cmd.in_back = 0
            cmd.in_moveleft = 0
            cmd.in_moveright = 0
            cmd.in_speed = 0
            cmd.forwardmove = 800
            cmd.sidemove = 0
            cmd.move_yaw = move_yaw
        end

        local function update_hitboxes(element, force_baim)
            local new_hitboxes = {}
            local target_hitboxes = ui.get(element)

            local force_baim_disabled_hitgroups = {'Head', 'Arms', 'Legs', 'Feet'}

            for i = 1, #target_hitboxes do
                if force_baim and contains(force_baim_disabled_hitgroups, target_hitboxes[i]) then
                    goto continue
                end

                local hitgroup = hitgroups_to_hitboxes[target_hitboxes[i]]

                for j = 1, #hitgroup do
                    local hitbox = hitgroup[j]

                    if contains(allowed_hitboxes, hitbox) then
                        table.insert(new_hitboxes, hitbox)
                    end
                end

                ::continue::
            end

            active_hitboxes = new_hitboxes
        end

        local function skip_func(entindex, contents_mask)
            if entity.get_classname(entindex) == 'CCSPlayer' and entity.is_enemy(entindex) then
                return false
            end

            return true
        end

        local function handle_point(position, prev_position, angle, step_distance, index, view_offset, vec_mins, vec_maxs, max_step)
            local start_pos = prev_position and
                (prev_position - view_offset) or
                position

            local pos = extend_vector(
                start_pos,
                index == 0 and 0 or step_distance,
                angle
            )

            local trace_up = trace.hull(
                start_pos, start_pos + vector(0, 0, max_step), vec_mins, vec_maxs, {skip = skip_func, mask = 0x201400B}
            ).end_pos

            local trace_horizontal = trace.hull(
                vector(start_pos.x, start_pos.y, trace_up.z),
                vector(pos.x, pos.y, trace_up.z),
                vec_mins, vec_maxs, {skip = skip_func, mask = 0x201400B}
            ).end_pos

            if pos:dist2d(trace_horizontal) >= step_distance * .97 then
                return false
            end

            local trace_down = trace.hull(
                trace_horizontal,
                vector(trace_horizontal.x, trace_horizontal.y, position.z - 240),
                vec_mins, vec_maxs, {skip = skip_func, mask = 0x201400B}
            ).end_pos

            return trace_down + view_offset
        end

        local function setup_points(local_player, position, angle, amount, step_distance)
            local view_offset = vector(
                entity.get_prop(local_player, 'm_vecViewOffset')
            )

            local vec_mins = vector(
                entity.get_prop(local_player, 'm_vecMins')
            )

            local vec_maxs = vector(
                entity.get_prop(local_player, 'm_vecMaxs')
            )

            cache.positions[0] = handle_point(
                position, nil, 0,
                step_distance, 0, view_offset,
                vec_mins, vec_maxs, max_step
            )

            for i = 1, amount do
                local angle = i % 2 == 0 and angle - 90 or angle + 90

                local prev_point = cache.positions[i <= 2 and 0 or i - 2]

                if not prev_point then
                    goto continue
                end

                local point = handle_point(
                    position, prev_point, angle,
                    step_distance, i, view_offset,
                    vec_mins, vec_maxs, max_step
                )

                if not point or (prev_point and math.abs(prev_point.z - point.z) > max_step) then
                    for k = i, amount, 2 do
                        cache.positions[k] = false
                    end

                    goto continue
                end

                cache.positions[i] = point

                ::continue::
            end

            return cache.positions
        end

        local function weapon_can_fire(player, weapon)
            local lp_NextAttack = entity.get_prop(player, 'm_flNextAttack')
            local wpn_NextPrimaryAttack = entity.get_prop(weapon, 'm_flNextPrimaryAttack')

            if math.max(0, lp_NextAttack or 0, wpn_NextPrimaryAttack or 0) > globals.curtime() or entity.get_prop(weapon, 'm_iClip1') <= 0 then
                return false
            end

            return true
        end

        local function can_target(local_player, target)
            if not target then
                return false
            end

            local lp_wpn = entity.get_player_weapon(local_player)

            if not weapon_can_fire(local_player, lp_wpn) then
                return false
            end

            local check_scope =
                not ui.get(reference.ragebot.aimbot.automatic_scope)
                and contains(scope_weapons, entity.get_classname(lp_wpn))
                and entity.get_prop(local_player, 'm_bIsScoped') ~= 1

            if check_scope then
                return false
            end

            if exploit.get().active and not exploit.get().charged then
                return false
            end

            if entity.get_prop(local_player, 'm_flVelocityModifier') ~= 1 then
                return false
            end

            local esp_data = entity.get_esp_data(target) or {alpha = 0}

            if esp_data.alpha < .75 then
                return false
            end

            return true
        end

        local function trace_enemy(positions, local_player, target, hitboxes)
            if target == nil then
                return nil, 0
            end

            local target_health = entity.get_prop(target, 'm_iHealth')
            local minimum_damage = reference.get_override_damage() and reference.is_override_minimum_damage()
            and reference.get_override_damage() or reference.get_minimum_damage()

            for i = 1, #positions do
                local pos = positions[i]

                if not pos then
                    goto continue
                end

                for j = 1, #hitboxes do
                    local hitbox = hitboxes[j]
                    local hitbox_pos = vector(
                        entity.hitbox_position(target, hitbox)
                    )

                    local entindex, damage = client.trace_bullet(
                        local_player,
                        pos.x, pos.y, pos.z,
                        hitbox_pos.x, hitbox_pos.y, hitbox_pos.z,
                        hitbox == 0 --bad fix
                    )

                    --bad fix
                    if hitbox == 0 then
                        damage = damage * 4
                    end

                    if damage >= math.min(minimum_damage, target_health) and damage > 0 then
                        return pos, i
                    end
                end

                ::continue::
            end

            return nil, 0
        end

        local function on_shutdown()
            ragebot.unset(reference.ragebot.aimbot.double_tap[1])
            override.unset(reference.antiaim.other.on_shot_antiaim[1])

            override.unset(reference.ragebot.other.quick_peek_assist[1])
            override.unset(reference.ragebot.other.quick_peek_assist[2])
            override.unset(reference.ragebot.other.quick_peek_assist_mode[1])
        end

        function peek_bot:update(cmd)
            local main_key = ref.checkbox:get() and ref.hotkey:get()

            if main_key and not hotkeys.main then
                local local_player = entity.get_local_player()
                local lp_origin = vector(entity.get_origin(local_player))
                cache.middle_pos = extrapolate_position(local_player, lp_origin, 13, true)
                hotkeys.main = true
            elseif not main_key and hotkeys.main then
                override.unset(reference.ragebot.other.quick_peek_assist[1])
                override.unset(reference.ragebot.other.quick_peek_assist[2])
                override.unset(reference.ragebot.other.quick_peek_assist_mode[1])

                -- override.unset(reference.ragebot.aimbot.double_tap[1])
                -- override.unset(reference.antiaim.other.on_shot_antiaim[1])

                hotkeys.main = false
            end

            local force_baim = ui.get(reference.ragebot.aimbot.force_body_aim)

            if force_baim and not hotkeys.force_baim then
                update_hitboxes(reference.ragebot.aimbot.target_hitbox, true)
                hotkeys.force_baim = true
            elseif not force_baim and hotkeys.force_baim then
                update_hitboxes(reference.ragebot.aimbot.target_hitbox)
                hotkeys.force_baim = false
            end

            if not main_key then
                targeting = false
                returning = false
                should_return = false
                teleport = false
                disable_exploit = false
                visual.active = false
                return
            end

            override.set(reference.ragebot.other.quick_peek_assist[1], true)
            override.set(reference.ragebot.other.quick_peek_assist[2], 'Always on')

            local move_mode = ref.type:get()

            local local_player = entity.get_local_player()
            local lp_velocity = vector(entity.get_prop(local_player, 'm_vecVelocity')):length2d()
            local tickcount = globals.tickcount()

            local local_override = bit.band(entity.get_prop(local_player, 'm_fFlags'), 1) ~= 1
            or (cmd.in_forward == 1 or cmd.in_moveleft == 1 or cmd.in_moveright == 1 or cmd.in_back == 1 or cmd.in_jump == 1)

            local lp_origin = vector(entity.get_origin(local_player))
            local middle_pos = cache.middle_pos
            local dist_to_middle = middle_pos:dist2d(lp_origin)

            if (move_mode == 'Offensive' and not targeting and not returning)
            or (dist_to_middle > .15 and lp_velocity < 1.011 and lp_velocity ~= 0) then
                cache.middle_pos = lp_origin
            end

            local target = client.current_threat()
            cache.current_target = target

            local target_origin = target and vector(entity.get_origin(target)) or vector()
            local angle = target and vector(middle_pos:to(target_origin):angles()).y or vector(client.camera_angles()).y

            local positions = setup_points(local_player, middle_pos, angle, amount, step_distance)

            visual.active = true

            local active_point_pos, active_point_index = nil, 0

            if not local_override and not returning and can_target(local_player, target) then
                active_point_pos, active_point_index = trace_enemy(
                    positions, local_player, target, active_hitboxes
                )
            end

            targeting = active_point_pos ~= nil
            cache.active_point_index = active_point_index

            if targeting then
                set_movement(cmd, active_point_pos, local_player)
                returning = false
                should_return = true
                teleport = false
                disable_exploit = false
            elseif local_override then
                returning = false
                should_return = false
                teleport = false
                disable_exploit = false
            elseif should_return or move_mode == 'Defensive' then
                returning = true
                should_return = false
                teleport = true
            end

            if not returning then
                cache.last_returning_time = tickcount
            end

            if returning then
                if dist_to_middle < .15 then
                    returning = false
                    teleport = false
                    disable_exploit = false
                elseif teleport then
                    if ui.get(reference.ragebot.aimbot.double_tap[1]) and ui.get(reference.ragebot.aimbot.double_tap[2])
                    and weapon_can_fire(local_player, entity.get_player_weapon(local_player)) then
                        if tickcount - cache.last_returning_time == 1 then
                            cmd.force_defensive = true
                        elseif tickcount - cache.last_returning_time >= 7 then
                            ragebot.set(reference.ragebot.aimbot.double_tap[1], false)
                            override.set(reference.antiaim.other.on_shot_antiaim[1], false)

                            teleport = false
                            disable_exploit = true
                        end
                    elseif not (ui.get(reference.ragebot.aimbot.double_tap[1]) and ui.get(reference.ragebot.aimbot.double_tap[2]))
                    and ui.get(reference.antiaim.other.on_shot_antiaim[1]) and ui.get(reference.antiaim.other.on_shot_antiaim[2]) then
                        if not exploit.get().defensive.active then
                            override.set(reference.antiaim.other.on_shot_antiaim[1], false)

                            teleport = false
                            disable_exploit = true
                        end
                    end
                end
            end

            if not teleport then
                ragebot.unset(reference.ragebot.aimbot.double_tap[1])
                override.unset(reference.antiaim.other.on_shot_antiaim[1])
            end

            if returning then
                override.set(reference.ragebot.other.quick_peek_assist_mode[1], returning and {'Retreat on shot', 'Retreat on key release'} or nil)
            else
                override.unset(reference.ragebot.other.quick_peek_assist_mode[1])
            end

            if disable_exploit then
                ragebot.set(reference.ragebot.aimbot.double_tap[1], false)
                override.set(reference.antiaim.other.on_shot_antiaim[1], false)
            else
                ragebot.unset(reference.ragebot.aimbot.double_tap[1])
                override.unset(reference.antiaim.other.on_shot_antiaim[1])
            end
        end

        local function on_paint()
            local local_player = entity.get_local_player()

            if not entity.is_alive(local_player) then
                return
            end

            local clr = color(ref.color:get())
            local data = cache.positions
            local color_ref = {clr.r, clr.g, clr.b, 255}
            local active = visual.active and ref.options:get 'Visualize'
            local values = visual.values
            local active_point = cache.active_point_index

            values.global_alpha = motion.interp(
                values.global_alpha, active, .045
            )

            local g_alpha = values.global_alpha

            if g_alpha <= 0 then
                return
            end

            for i = 0, #data do
                local pos = data[i]

                if pos == nil then
                    goto continue
                end

                if not values.alpha[i] then
                    values.alpha[i] = 0
                end

                if not values.pos[i] then
                    values.pos[i] = vector()
                end

                values.alpha[i] = motion.interp(
                    values.alpha[i], pos and active, 0.045
                )

                local alpha = values.alpha[i]

                if alpha <= 0 then
                    goto continue
                end

                if pos then
                    local t = alpha > .15 and .02 or 0

                    values.pos[i].x = motion.interp(values.pos[i].x, pos.x, t)
                    values.pos[i].y = motion.interp(values.pos[i].y, pos.y, t)
                    values.pos[i].z = motion.interp(values.pos[i].z, pos.z - 26 + 5 * alpha + (active_point == i and 2 or 0), t)
                end

                local pos_screen = vector(renderer.world_to_screen(values.pos[i]:unpack()))

                if pos_screen.x ~= 0 then
                    local clr = active_point == i and color_ref or {clr.r, clr.g, clr.b, 100}
                    renderer.circle(pos_screen.x, pos_screen.y, clr[1], clr[2], clr[3], clr[4] * alpha, 3, 0, 1)
                end

                local prev_index = i <= 2 and 0 or i - 2
                local line_from = vector(renderer.world_to_screen(values.pos[prev_index]:unpack()))
                local line_to = vector(renderer.world_to_screen(values.pos[i]:unpack()))

                if line_from.x ~= 0 and line_to.x ~= 0 then
                    renderer.line(line_from.x, line_from.y, line_to.x, line_to.y, clr.r, clr.g, clr.b, 100 * alpha)
                end

                ::continue::
            end
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if not value then
                    on_shutdown()
                end

                utils.event_callback('shutdown', on_shutdown)

                utils.event_callback('paint', on_paint, value)
                update_hitboxes(reference.ragebot.aimbot.target_hitbox)
            end

            ref.checkbox:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local other_clone = { } do
        local ref = menu_elements.antiaim.features

        local HOTKEY_MODE = {
            [0] = 'Always on',
            [1] = 'On hotkey',
            [2] = 'Toggle',
            [3] = 'Off hotkey'
        }

        local function get_hotkey_value(_, mode, key)
            return HOTKEY_MODE[mode], key or 0
        end

        function other_clone:shutdown()
            override.unset(reference.antiaim.other.slow_motion[1])
            override.unset(reference.antiaim.other.slow_motion[2])

            override.unset(reference.antiaim.other.on_shot_antiaim[1])
            override.unset(reference.antiaim.other.on_shot_antiaim[2])

            override.unset(reference.antiaim.other.fake_peek[1])
            override.unset(reference.antiaim.other.fake_peek[2])
        end

        function other_clone:update()
            override.set(reference.antiaim.other.slow_motion[1], ref.slow_motion.checkbox:get())
            override.set(reference.antiaim.other.slow_motion[2], get_hotkey_value(ref.slow_motion.hotkey:get()))

            override.set(reference.antiaim.other.on_shot_antiaim[1], ref.osaa.checkbox:get())
            override.set(reference.antiaim.other.on_shot_antiaim[2], get_hotkey_value(ref.osaa.hotkey:get()))

            override.set(reference.antiaim.other.fake_peek[1], ref.fake_peek.checkbox:get())
            override.set(reference.antiaim.other.fake_peek[2], get_hotkey_value(ref.fake_peek.hotkey:get()))
        end
    end

    local function on_shutdown()
        other_clone:shutdown()

        ragebot.unset(reference.ragebot.aimbot.enabled[1])
        ragebot.unset(reference.ragebot.aimbot.double_tap[1])
    end

    local function on_setup_command(cmd)
        other_clone:shutdown()
        other_clone:update()

        ragebot.unset(reference.ragebot.aimbot.enabled[1])
        ragebot.unset(reference.ragebot.aimbot.double_tap[1])

        unsafe_exploit_recharge:update(cmd)

        if not auto_on_shot_antiaim:update(cmd) then
            auto_discharge:update(cmd)
        end

        peek_bot:update(cmd)
    end

    local function on_pre_config_save()
        other_clone:shutdown()
    end

    utils.event_callback('shutdown', on_shutdown)
    utils.event_callback('setup_command', on_setup_command)
    utils.event_callback('pre_config_save', on_pre_config_save)
end

local misc do
    local drop_nades = { } do
        local ref = menu_elements.other.miscellaneous.drop_nades

        local queue = { }

        local throwing = false
        local old_state = nil

        local function clear_queue()
            for i = 1, #queue do
                queue[i] = nil
            end
        end

        local function is_allowed_class(item_class)
            if item_class == 'weapon_hegrenade' then
                return ref.grenades:get 'HE Grenade'
            end

            if item_class == 'weapon_smokegrenade' then
                return ref.grenades:get 'Smoke'
            end

            if item_class == 'weapon_incgrenade' or item_class == 'weapon_molotov' then
                return ref.grenades:get 'Molotov'
            end

            return false
        end

        local function is_weapon_allowed(weapon)
            local info = csgo_weapons(weapon)

            if info.weapon_type_int ~= 9 then
                return false
            end

            if not is_allowed_class(info.item_class) then
                return false
            end

            return true
        end

        local function update_queue(ent)
            local weapons = utils.get_player_weapons(ent)

            for i = 1, #weapons do
                local weapon = weapons[i]

                if not is_weapon_allowed(weapon) then
                    goto continue
                end

                table.insert(queue, weapon)
                ::continue::
            end
        end

        local function on_setup_command(cmd)
            local me = entity.get_local_player()

            if me == nil then
                return
            end

            local weapon = entity.get_player_weapon(me)

            if weapon == nil then
                return
            end

            local state = ref.hotkey:get()

            if old_state ~= state then
                old_state = state

                if state and not throwing then
                    clear_queue()
                    update_queue(me)

                    throwing = next(queue) ~= nil
                end
            end

            local latency = client.latency() + totime(4)

            for i = 1, #queue do
                local grenade = queue[i]

                if grenade == nil then
                    goto continue
                end

                local weapon_info = csgo_weapons(grenade)

                if weapon_info == nil then
                    goto continue
                end

                local last = i == #queue

                client.delay_call(latency * i, function()
                    client.exec(string.format(
                        'use %s; drop', weapon_info.item_class
                    ))

                    if last then
                        client.delay_call(0.1, function()
                            throwing = false
                        end)
                    end
                end)

                ::continue::
            end

            clear_queue()

            if throwing then
                local pitch, yaw = client.camera_angles()

                local offset = 0.0001

                if pitch > 0 then
                    offset = -offset
                end

                cmd.yaw = yaw
                cmd.pitch = pitch + offset

                cmd.no_choke = true
                cmd.allow_send_packet = true
            end
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if not value then
                    clear_queue()
                end

                utils.event_callback(
                    'setup_command',
                    on_setup_command,
                    value
                )
            end

            ref.checkbox:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local edge_quick_stop = { } do
        local ref = menu_elements.other.miscellaneous.edge_quick_stop

        local max_distance = 70
        local step_distance = 2
        local safe_step_height = 40
        local drop_depth = 40
        local outer_distance = 80
        local coyote_allowance = 20
        local blocked_directions = { }

        local function check_direction_dual(player, yaw, offset)
            local ox, oy, oz = entity.get_prop(player, "m_vecOrigin")
            local rad = math.rad(yaw + offset)
            local dx, dy = math.cos(rad), math.sin(rad)

            local safe_dist = 0
            local edge_point = nil
            local outer_safe = false

            for dist = step_distance, max_distance, step_distance do
                local fx = ox + dx * dist
                local fy = oy + dy * dist
                local fz = oz + 5

                local frac_down = select(
                    1, client.trace_line(player, fx, fy, fz, fx, fy, fz - drop_depth)
                )

                if frac_down == 1.0 or (frac_down * drop_depth) > safe_step_height then
                    edge_point = {fx, fy, fz}
                    break
                end

                safe_dist = dist
            end

            local ox2 = ox + dx * outer_distance
            local oy2 = oy + dy * outer_distance
            local oz2 = oz + 5

            local frac_outer = select(
                1, client.trace_line(player, ox2, oy2, oz2, ox2, oy2, oz2 - drop_depth)
            )

            outer_safe = not (frac_outer == 1.0 or (frac_outer * drop_depth) > safe_step_height)

            return safe_dist, edge_point, outer_safe
        end

        local function on_setup_command(cmd)
            if not ref.checkbox:get() then
                return
            end

            if not ref.hotkey:get() then
                return
            end

            local lp = entity.get_local_player()
            if not lp or not entity.is_alive(lp) then
                return
            end

            local flags = entity.get_prop(lp, "m_fFlags") or 0
            if bit.band(flags, 1) == 0 then
                return
            end

            local _, yaw = client.camera_angles()
            if not yaw then
                return
            end

            blocked_directions = {
                forward = 0, back = 0, left = 0, right = 0
            }

            local dirs = {
                forward = 0, back = 180, left = 90, right = -90
            }

            for name, ang in pairs(dirs) do
                local safe_dist, _, outer_safe = check_direction_dual(lp, yaw, ang)
                if safe_dist < max_distance then
                    if outer_safe then
                        blocked_directions[name] = safe_dist + coyote_allowance
                    else
                        blocked_directions[name] = safe_dist
                    end
                else
                    blocked_directions[name] = nil
                end
            end

            if cmd.forwardmove ~= 0 then
                local sign = cmd.forwardmove > 0 and 1 or -1
                local key = sign == 1 and "forward" or "back"
                local safe = blocked_directions[key]
                if safe and safe < max_distance then
                    cmd.forwardmove = cmd.forwardmove * (safe / max_distance)
                end
            end

            if cmd.sidemove ~= 0 then
                local sign = cmd.sidemove > 0 and 1 or -1
                local key = sign == 1 and "right" or "left"
                local safe = blocked_directions[key]
                if safe and safe < max_distance then
                    cmd.sidemove = cmd.sidemove * (safe / max_distance)
                end
            end
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                utils.event_callback(
                    'setup_command',
                    on_setup_command,
                    value
                )
            end

            ref.checkbox:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local item_crash_fix = { } do
        local ref = menu_elements.other.miscellaneous

        local CS_UM_SendPlayerItemFound = 63

        local DispatchUserMessage_t = ffi.typeof [[
            bool(__thiscall*)(void*, int msg_type, int nFlags, int size, const void* msg)
        ]]

        local VClient018 = client.create_interface('client.dll', 'VClient018')

        local pointer = ffi.cast('uintptr_t**', VClient018)
        local vtable = ffi.cast('uintptr_t*', pointer[0])

        local size = 0

        while vtable[size] ~= 0x0 do
            size = size + 1
        end

        local hooked_vtable = ffi.new('uintptr_t[?]', size)

        for i = 0, size - 1 do
            hooked_vtable[i] = vtable[i]
        end

        local oDispatch = ffi.cast(DispatchUserMessage_t, vtable[38])

        local function hkDispatch(thisptr, msg_type, nFlags, size, msg)
            if msg_type == CS_UM_SendPlayerItemFound then
                return false
            end

            return oDispatch(thisptr, msg_type, nFlags, size, msg)
        end

        local hook_ptr = ffi.cast('uintptr_t', ffi.cast(DispatchUserMessage_t, hkDispatch))

        local function set_hook()
            pointer[0] = hooked_vtable
            hooked_vtable[38] = hook_ptr
        end

        local function unset_hook()
            hooked_vtable[38] = vtable[38]
            pointer[0] = vtable
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if value then
                    set_hook()
                else
                    unset_hook()
                end

                utils.event_callback('shutdown', unset_hook, value)
            end

            ref.item_crash_fix:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local allow_duck_on_fd = { } do
        local ref = menu_elements.other.miscellaneous

        local ref_duck_peek_assist = ui.reference(
            'Rage', 'Other', 'Duck peek assist'
        )

        local should_override = false

        local function on_shutdown()
            override.unset(ref_duck_peek_assist)
        end

        local function on_setup_command(cmd)
            local me = entity.get_local_player()

            if me == nil then
                return
            end

            local duck_amount = entity.get_prop(
                me, 'm_flDuckAmount'
            )

            local should_unoverride = (
                ui.is_menu_open() or
                cmd.in_duck == 0 or
                not localplayer.is_onground
            )

            if should_unoverride then
                should_override = false
            elseif duck_amount > 0.75 then
                should_override = true
            end

            if should_override then
                override.set(ref_duck_peek_assist, 'On hotkey', 0)
            else
                override.unset(ref_duck_peek_assist)
            end
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if not value then
                    override.unset(ref_duck_peek_assist)
                end

                utils.event_callback(
                    'shutdown',
                    on_shutdown,
                    value
                )

                utils.event_callback(
                    'setup_command',
                    on_setup_command,
                    value
                )
            end

            ref.allow_duck_on_fd:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local reveal_enemy_team_chat = { } do
        local ref = menu_elements.other.miscellaneous

        local game_state_api = panorama.open().GameStateAPI

        local cl_mute_enemy_team = cvar.cl_mute_enemy_team
        local cl_mute_all_but_friends_and_party = cvar.cl_mute_all_but_friends_and_party

        local chat_data = { }

        local function on_player_say(e)
            local entindex = client.userid_to_entindex(e.userid)

            if not entity.is_enemy(entindex) then
                return
            end

            local xuid = game_state_api.GetPlayerXuidStringFromEntIndex(entindex)

            if game_state_api.IsSelectedPlayerMuted(xuid) then
                return
            end

            if cl_mute_enemy_team:get_int() == 1 then
                return
            end

            if cl_mute_all_but_friends_and_party:get_int() == 1 then
                return
            end

        end

        local function on_player_chat(e)
            if not entity.is_enemy(e.entity) then
                return
            end

            chat_data[e.entity] = globals.realtime()
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                utils.event_callback(
                    'player_say',
                    on_player_say,
                    value
                )

                utils.event_callback(
                    'player_chat',
                    on_player_chat,
                    value
                )
            end

            ref.enemy_chat_viewer:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local automatic_purchase = { } do
        local ref = menu_elements.other.miscellaneous.automatic_purchase

        local mp_afterroundmoney = cvar.mp_afterroundmoney

        local primary_items = {
            ['AWP'] = 'awp',
            ['Scout'] = 'ssg08',
            ['G3SG1 / SCAR-20'] = 'scar20'
        }

        local secondary_items = {
            ['P250'] = 'p250',
            ['Elites'] = 'elite',
            ['Five-seven / Tec-9 / CZ75'] = 'fn57',
            ['Deagle / Revolver'] = 'deagle'
        }

        local equipment_items = {
            ['Kevlar'] = 'vest',
            ['Kevlar + Helmet'] = 'vesthelm',
            ['Defuse kit'] = 'defuser',
            ['HE'] = 'hegrenade',
            ['Smoke'] = 'smokegrenade',
            ['Molotov'] = 'molotov',
            ['Taser'] = 'taser'
        }

        local function should_buy()
            local me = entity.get_local_player()

            if me == nil then
                return
            end

            local account = entity.get_prop(
                me, 'm_iAccount'
            )

            if ref.options:get 'Ignore pistol round' then
                if account <= 1000 then
                    return false
                end
            end

            if ref.options:get 'Only $16k' then
                local after_round_money = mp_afterroundmoney:get_int()

                return account >= 16000
                    or after_round_money >= 16000
            end

            return true
        end

        local function should_buy_reserved()
            local me = entity.get_local_player()

            if me == nil then
                return false
            end

            local weapons = utils.get_player_weapons(me)

            for i = 1, #weapons do
                local weapon = weapons[i]

                local weapon_info = csgo_weapons(weapon)

                if weapon_info == nil then
                    goto continue
                end

                local weapon_idx = weapon_info.idx

                if weapon_idx == 9 then
                    return false
                end

                ::continue::
            end

            return true
        end

        local function buy_primary(list)
            local item = primary_items[
                ref.primary:get()
            ]

            if item == nil then
                return
            end

            if item == 'awp' then
                local function on_awp()
                    if not should_buy_reserved() then
                        return
                    end

                    local reserv = primary_items[
                        ref.alternative:get()
                    ]

                    if reserv == nil then
                        return
                    end

                    client.exec('buy ' .. reserv)
                end

                local duration = client.latency() + 0.15

                client.delay_call(duration, on_awp)
            end

            table.insert(list, item)
        end

        local function buy_secondary(list)
            local item = secondary_items[
                ref.secondary:get()
            ]

            if item ~= nil then
                table.insert(list, item)
            end
        end

        local function buy_equipment(list)
            local values = ref.equipment:get()

            for i = 1, #values do
                local value = equipment_items[
                    values[i]
                ]

                if value ~= nil then
                    table.insert(list, value)
                end
            end
        end

        local function process_buy()
            if not should_buy() then
                return
            end

            local list = { }

            buy_primary(list)
            buy_secondary(list)
            buy_equipment(list)

            local command = ''

            for i = 1, #list do
                local item = list[i]

                command = command .. string.format(
                    'buy %s;', item
                )
            end

            if command ~= '' then
                client.exec(command)
            end
        end

        local function on_round_prestart()
            client.delay_call(client.latency() + totime(8), process_buy)
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                utils.event_callback(
                    'round_prestart',
                    on_round_prestart,
                    value
                )
            end

            ref.checkbox:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local trash_talk = { } do
        local ref = menu_elements.other.miscellaneous.trash_talk

        local phrases = {
            bait = {
                {'1', 1.0}
            },

            kill = {
                {'ʙʏ ʙᴜʏɪɴɢ ᴇᴍʙᴇʀʟᴀsʜ, ʏᴏᴜ\'ʀᴇ ʙᴜʏɪɴɢ ᴀ ᴛɪᴄᴋᴇᴛ ᴛᴏ ʜᴇʟʟ.', 0.2},
                {'𝙀𝙢𝙗𝙚𝙧𝙡𝙖𝙨𝙝 𝙥𝙧𝙚𝙢𝙞𝙪𝙢 𝙥𝙧𝙚𝙙𝙞𝙘𝙩𝙞𝙤𝙣 𝙩𝙚𝙘𝙝𝙣𝙤𝙡𝙤𝙜𝙞𝙚𝙨 ◣◢ 👑', 0.2},
                {'The Flame will never die, for I am EMBERLASH', 0.2},
                {'☾ 𝕘𝕖𝕥 𝕗𝕦𝕔𝕜𝕖𝕕 𝕓𝕪 𝕕𝕖𝕧𝕚𝕝 #𝕖𝕞𝕓𝕖𝕣𝕝𝕒𝕤𝕙 ~ 𝕟𝕖𝕥𝕨𝕠𝕣k ☾', 0.2, '1', 1.0},
                {'♥️ Очередная душа в мою копилку (◣_◢) ♥️', 0.2},
                {'теперь сам Дьявол объявил на тебя охоту #𝕖𝕞𝕓𝕖𝕣𝕝𝕒𝕤𝕙 ☾', 0.2},
                {'опять слезы? умоляй моих дьяволов выдать тебе emberlash', 0.2},
                {'1', 1.0},
                {'𝕖𝕞𝕓𝕖𝕣𝕝𝕒𝕤𝕙 𝕚𝕤 𝕥𝕙𝕖 𝕓𝕖𝕤𝕥 𝔸𝔸 𝔸𝔸 𝔸𝔸 𝔸𝔸 𝔸𝔸 𝔸𝔸 𝔸', 0.2},
                {'♆ Сливы Дьяволиц -> .𝕘𝕘/𝔼𝕞𝕓𝕖𝕣𝕝𝕒𝕤𝕙 ♆', 0.2},
                {'#𝙚𝙢𝙗𝙚𝙧𝙡𝙖𝙨𝙝 𝙘𝙤𝙙𝙚 𝙬𝙖𝙨 𝙬𝙧𝙞𝙩𝙩𝙚𝙣 𝙗𝙮 𝐵𝓁𝑜𝑜𝒹 𝑜𝒻 𝐿𝓊𝒸𝒾𝒻𝑒𝓇 ٩(×̯×)۶', 0.2},
                {'14fl peek but i still predict #mephissa predict', 0.2},
                {'1', 1.0},
                {'твоя сила – лишь иллюзия перед властью Emberlash.', 0.2},
                {'это не битва, это исповедь, emberlash выслушает все твои грехи.', 0.2},
                {'Это не борьба за выживание, это жертва Emberlash.', 0.2},
                {'1', 1.0},
                {'emberlash станет эпитафией на твоём надгробии.', 0.2},
                {'Estk came to my door last night and said emberlash best ◣◢ I say ok king 👑', 0.2},
                {'𝕘𝕠𝕕 𝕘𝕒𝕧𝕖 𝕞𝕖 𝕡𝕠𝕨𝕖𝕣 𝕠𝕗 𝕣𝕖𝕫𝕠𝕝𝕧𝕖𝕣 𝔼𝕄𝔹𝔼ℝ𝕃𝔸𝕊ℍ', 0.2},
                {'っ◔◡◔)っ ♥ enjoy die to emberlash and spectate me ♥', 0.2},
                {'1', 1.0},
                {'𝕟𝕠 𝕤𝕜𝕚𝕝𝕝 𝕟𝕖𝕖𝕕 𝕛𝕦𝕤𝕥 𝕖𝕞𝕓𝕖𝕣𝕝𝕒𝕤𝕙', 0.2},
                {'𝕚 𝕒𝕞 𝕚𝕥”𝕤 𝕕𝕠𝕟𝕥 𝕝𝕠𝕤𝕖  ◣◢ #emberlash', 0.2},
                {'god may forgive you but emberlash resolver wont (◣_◢)', 0.2},
                {'1', 1.0},
                {'𝕓𝕪 𝕤𝕚𝕘𝕟𝕚𝕟𝕘 𝕒 𝕔𝕠𝕟𝕥𝕒𝕔𝕥 𝕨𝕚𝕥𝕙 𝕥𝕙𝕖 𝕕𝕖𝕧𝕚𝕝 𝕪𝕠𝕦 𝕒𝕣𝕖 𝕕𝕠𝕠𝕞𝕖𝕕 𝕥𝕠 𝕕𝕚𝕖 #emberlash', 0.2},
                {'ＹＯＵ ＷＩＳＨ ＹＯＵ ＨＡＤ E M B E R L A S H Ｕ ＨＲＳＮ', 0.2},
                {'winning not possibility, sry #emberlash', 0.2},
                {'1', 1.0},
                {'𝙙𝙖𝙮 666 𝗲𝗺𝗯𝗲𝗿𝗹𝗮𝘀𝗵 𝙨𝙩𝙞𝙡𝙡 𝙣𝙤 𝙧𝙞𝙫𝙖𝙡𝙨', 0.2},
                {'once this game started 𝔂𝓸𝓾 𝓵𝓸𝓼𝓮𝓭 𝓪𝓵𝓻𝓮𝓭𝔂 #emberlash', 0.2},
                {'ＹＯＵ ＨＡＤ ＦＵＮ ＬＡＵＧＨＩＮＧ ＵＮＴＩＬ ＮＯＷ #emberlash', 0.2},
                {'1', 1.0},
                {'EMBERLASH SEASON ON TRƱE #WITCHHOUSE AND #EVIL RADIO vibe 2025™', 0.2},
                {'rock star lifestyle #EMBERLASH', 0.2},
                {'i love emberlash', 0.2, 'do you love it?', 1},
                {'1', 1.0},
                {'zｚＺ', 0.2, 'playing with emberlash is so boooring', 0.5},
                {'im cursed', 0.2, 'satan is watching us', 0.6},
                {'family-friendly lua -> .gg/emberlash', 0.2},
                {'1', 1.0},
                {'1', 0.5, 'теперь думай кто это написал)))', 0.8},
                {'мы летим низко', 0.2, 'в бошке храню все emberlash', 0.5},
                {'снова палю в экран', 0.5, 'снова вижу этот дискорд', 0.5, '.gg/emberlash', 0.5},
                {'1', 0.4, 'иди ты нахуй дебилина', 0.5},
                {'1', 0.4, 'ФХАФЫХАЫХФАХ', 0.5, 'бомж ты куда', 0.6},
                {'моя сила emberlash', 0.2, 'что не брикаю лцшечку', 0.5},
                {'это происходит в действительности?', 0.2, '1', 0.7},
                {'я смотрю', 0.2, 'у тебя тренировка по удачному спаму пуль, продолжай', 0.5},
                {'если бы твой скилл зависел от интеллекта', 0.2, 'ты бы и в меню не зашёл', 0.5},
                {'ты не победил', 0.2, 'я просто протестировал баг на перерождение', 0.7},
                {'1', 1.0},
                {'где тебя научили стрелять', 0.2, 'в тире для первоклассников?', 0.6},
                {'z бы тебя похвалил', 0.2, 'но ты выиграл не скиллом', 0.5, 'а везением', 0.8},
                {'ты - как бесплатный emberlash', 0.2, 'который никто не скачивает', 0.6},
                {'1', 1.0},
                {'если твои успехи в игре перевести в реальные достижения', 0.6, 'ты бы был миллионером… в минусах', 0.75},
                {'мой труп был в 100 раз полезнее команды', 0.4, 'чем ты живой', 0.5},
                {'это было настолько случайно, что даже твои родители не так удивились, когда ты родился', 0.5},
                {'1', 1.0},
                {'eсли бы IQ был оружием', 0.3, 'ты бы ходил с деревянной палкой', 0.5},
                {'ты ошибка природы', 0.3, 'и даже код игры это понимает', 0.6},
                {'каково жить с осознанием', 0.3, 'что даже удача тебя презирает?', 0.6},
                {'1', 1.0},
                {'если бы победы давали смысл жизни', 0.3, 'ты бы уже повесился', 0.4},
                {'интеллект у тиа бл такой же плоский, как шахматная доска в аду', 0.4},
                {'ты как шут', 0.2, 'пытающийся быть серьезным в компании демонов', 0.5},
                {'1', 1.0},
                {'ты меня убил', 0.2, 'как сочник', 0.4, 'который заигрался и случайно открыл портал в ад', 0.6}
            },

            death = {
                {'ну он же реально', 3, 'подрывает себя', 2.5, 'и я не могу попасть', 1.8},
                {'ты че ваще ебанутый?', 1, 'я твою мать ебал', 2, 'ебаный тупой ублюдок', 3},
                {'в этом раунде эмберлашик не прокерил', 0.5, 'значит прокерит в следующем', 1.0},
                {'опять говно убивает', 1.8, 'я просто не могу уже', 1.5},
                {'ну как ты мои антиаимы тапаешь в эмберлаше??', 0.5, 'че ебу дал?', 1.0},
                {'я не могу в тебя попасть', 0.5, 'сделаешь мне такие же пресетики?', 1.5, 'на emberlash.gs', 0.5},
                {'НУ ЧТО ТЫ ЗА ДОЛБОЕБ', 0.2, 'БЛЯДИНА ЕБАНА Я ТЬЯВОЮ МАТЬ ЕБАЛ', 1.8},
                {'сын шлюхи ебаной я просто не знаю как тебя ещё назвать', 0.9, 'за твои действия пидарас', 1.5},
                {'какой же ты ХУЕСОС', 1.8, 'НУ Я МИССАЮ ЕМУ В РУКУ А ОН ДУМАЕТ', 0.8, 'ЧТО ЭТО ЛЦ', 1.4}
            }
        }

        local phrase_count = {
            bait = 0,
            kill = 0,
            death = 0
        }

        local function say_phrases(phrase_table)
            local current_delay = 0

            for i = 1, #phrase_table, 2 do
                local message = phrase_table[i]
                local delay = phrase_table[i + 1] or 3

                current_delay = current_delay + delay
                client.delay_call(current_delay, function()
                    client.exec(('say %s'):format(message))
                end)
            end
        end

        local function on_player_death(e)
            local player, victim, attacker =
                entity.get_local_player(),
                client.userid_to_entindex(e.userid),
                client.userid_to_entindex(e.attacker)
            if not player or not victim or not attacker then
                return
            end

            if attacker == player and victim ~= player then
                phrase_count.bait = (phrase_count.bait % #phrases.bait) + 1
                phrase_count.kill = (phrase_count.kill % #phrases.kill) + 1
            elseif victim == player and attacker ~= player then
                phrase_count.death = (phrase_count.death % #phrases.death) + 1
            end

            local selected_phrases = {
                bait = phrases.bait[phrase_count.bait],
                kill = phrases.kill[phrase_count.kill],
                death = phrases.death[phrase_count.death]
            }

            local phase = nil

            if ref.type:get() == 'Kamibebra' then
                phase = selected_phrases.kill or selected_phrases.death
            end

            if ref.type:get() == 'Bait' then
                phase = selected_phrases.bait
            end

            if phase == nil then
                return
            end

            local is_kill =
                ref.events:get 'On kill' and
                attacker == player and
                victim ~= player

            local is_death =
                ref.events:get 'On death' and
                victim == player and
                attacker ~= player

            if is_kill or is_death then
                say_phrases(phase)
            end
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                utils.event_callback(
                    'player_death',
                    on_player_death,
                    value
                )
            end

            ref.checkbox:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local console_filter = { } do
        local ref = menu_elements.other.miscellaneous

        local con_filter_enable = cvar.con_filter_enable
        local con_filter_text = cvar.con_filter_text

        local function restore_values()
            con_filter_enable:set_int(tonumber(con_filter_enable:get_string()))
            con_filter_text:set_string('')
        end

        local function update_values()
            con_filter_enable:set_raw_int(1)
            con_filter_text:set_string('[gamesense]')
        end

        local function update_loop()
            if not ref.console_filter:get() then
                return
            end

            update_values()

            client.delay_call(
                1, update_loop
            )
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if not value then
                    restore_values()
                end

                update_loop()
            end

            ref.console_filter:set_callback(
                update_event_callbacks, true
            )
        end
    end

    local clan_tag_spammer = { } do
        local ref = menu_elements.other.miscellaneous

        local old_text = nil

        local sequence = {
            '               ',
            '@              ',
            '#k             ',
            '|ka            ',
            '*kam           ',
            '@kami          ',
            '#kamib         ',
            '|kamibe        ',
            '*kamibeb       ',
            '@kamibebr      ',
            '#kamibebra     ',
            ' kamibebra    ',
            '  kamibebra   ',
            '   kamibebra  ',
            '    kamibebra ',
            '     kamibebra',
            '     kamibebr%',
            '      kamibeb$',
            '       kamibe&',
            '        kamib*',
            '         kami#',
            '          kam@',
            '           ka|',
            '            k%',
            '             $',
            '              '
        }

        local function set_clan_tag(text)
            if old_text ~= text then
                old_text = text

                client.set_clan_tag(text)
            end
        end

        local function unset_clan_tag()
            client.set_clan_tag('')

            client.delay_call(
                0.3, client.set_clan_tag, ''
            )
        end

        local function on_shutdown()
            unset_clan_tag()
        end

        local function on_net_update_start()
            local time = math.floor(
                globals.curtime() * 3.0
            )

            local index = time % #sequence
            local text = sequence[index + 1]

            set_clan_tag(text)
        end

        local callbacks do
            local function update_event_callbacks(item)
                local value = item:get()

                if not value then
                    unset_clan_tag()
                end

                utils.event_callback(
                    'shutdown',
                    on_shutdown,
                    value
                )

                utils.event_callback(
                    'net_update_start',
                    on_net_update_start,
                    value
                )
            end

            ref.clantag:set_callback(
                update_event_callbacks, true
            )
        end
    end

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

    local animations = { } do
        local ref = menu_elements.other.miscellaneous.animations

        local ANIMATION_LAYER_MOVEMENT_MOVE = 6
        local ANIMATION_LAYER_LEAN = 12

        local function update_moving_legs(player, entity_info)
            local mode = ref.moving.type:get()

            if mode == 'Off' then
                return
            end

            if mode == 'Static' then
                entity.set_prop(player, 'm_flPoseParameter', 1, 0)
                override.set(reference.antiaim.other.leg_movement, 'Always slide')

                return
            end

            if mode == 'Jitter' then
                local value = utils.random_float(
                    ref.moving.min_jitter:get() * 0.01,
                    ref.moving.max_jitter:get() * 0.01
                )

                entity.set_prop(player, 'm_flPoseParameter', value, 7)
                override.set(reference.antiaim.other.leg_movement, 'Never slide')

                return
            end

            if mode == 'Alternative Jitter' then
                override.set(reference.antiaim.other.leg_movement, globals.commandack() % 3 == 0 and 'Off' or 'Always slide')
                entity.set_prop(player, 'm_flPoseParameter', 1, globals.tickcount() % 4 > 1 and 0.5 or 1)

                if not localplayer.is_moving then
                    entity.set_prop(player, 'm_flPoseParameter', utils.random_float(0.4, 0.8), 7)
                end

                return
            end

            if mode == 'Allah' then
                entity.set_prop(player, 'm_flPoseParameter', 1, 7)
                override.set(reference.antiaim.other.leg_movement, 'Never slide')

                return
            end
        end

        local function update_moving_body_lean(entity_info)
            if not ref.moving.options:get 'Body Lean' then
                return
            end

            local layer = entity_info:get_anim_overlay(ANIMATION_LAYER_LEAN)

            if layer == nil then
                return
            end

            layer.weight = ref.moving.body_lean:get() * 0.01
        end

        local function update_in_air_legs(player, entity_info)
            local mode = ref.air.type:get()

            if mode == 'Off' then
                return
            end

            if mode == 'Static' then
                entity.set_prop(player, 'm_flPoseParameter', 1, 6)

                return
            end

            if mode == 'Jitter' then
                local value = utils.random_float(
                    ref.air.min_jitter:get() * 0.01,
                    ref.air.max_jitter:get() * 0.01
                )

                entity.set_prop(player, 'm_flPoseParameter', value, 6)

                return
            end

            if mode == 'Allah' then
                local layer = entity_info:get_anim_overlay(ANIMATION_LAYER_MOVEMENT_MOVE)

                if layer == nil then
                    return
                end

                layer.weight = 1
                layer.cycle = globals.realtime() / 2 % 1

                entity.set_prop(player, 'm_flPoseParameter', 1, 6)

                return
            end
        end

        local function update_in_air_body_lean(entity_info)
            if not ref.air.options:get 'Body Lean' then
                return
            end

            local layer = entity_info:get_anim_overlay(ANIMATION_LAYER_LEAN)

            if layer == nil then
                return
            end

            layer.weight = ref.air.body_lean:get() * 0.01
        end

        local function update_pitch_on_land(player, entity_info)
            if not ref.moving.options:get 'Zero Pitch On Landing' then
                return
            end

            local animstate = entity_info:get_anim_state()

            if animstate == nil or not animstate.hit_in_ground_animation then
                return
            end

            entity.set_prop(player, 'm_flPoseParameter', 0.5, 12)
        end

        local function on_shutdown()
            override.unset(reference.antiaim.other.leg_movement)
        end

        local function on_pre_render()
            local me = entity.get_local_player()

            if me == nil then
                return
            end

            local entity_info = c_entity(me)

            if entity_info == nil then
                return
            end

            override.unset(reference.antiaim.other.leg_movement)

            if localplayer.is_onground then
                update_moving_legs(me, entity_info)
                update_moving_body_lean(entity_info)

                update_pitch_on_land(me, entity_info)
            end

            if not localplayer.is_onground then
                update_in_air_legs(me, entity_info)
                update_in_air_body_lean(entity_info)
            end
        end

        local callbacks do
            local function on_enabled(item)
                local value = item:get()

                if not value then
                    override.unset(reference.antiaim.other.leg_movement)
                end

                utils.event_callback('shutdown', on_shutdown, value)
                utils.event_callback('pre_render', on_pre_render, value)
            end

            ref.checkbox:set_callback(
                on_enabled, true
            )
        end
    end
end

local antiaim do
    local buffer = { } do
        local ref = reference.antiaim.angles

        local function override_value(item, ...)
            if ... == nil then
                return
            end

            override.set(item, ...)
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
            end

            function Buffer:set()
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
                    override_value(ref.freestanding[1], false)
                    override_value(ref.freestanding[2], 'On hotkey')
                end

                override_value(ref.roll, self.roll)
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

        local skitter = {
            -1, 1, 0,
            -1, 1, 0,
            -1, 0, 1,
            -1, 0, 1
        }

        -- 'Sequence': prime-length (11) multiplier cycle with uneven
        -- magnitudes - never lines up with 2/3/4-tick pattern matchers,
        -- and the varying deltas fail jitter-consistency checks that
        -- expect two alternating extremes
        local sequence_steps = {
            -1, 0.6, -0.2, 1, -0.75, 0.35, -1, 0.85, -0.5, 1, 0.1
        }

        function buffer_mods:get_yaw_inverted()
            return yaw_inverted
        end

        function buffer_mods:get_yaw_inverts()
            return yaw_inverts
        end

        function buffer_mods:update_inverter()
            local delay = nil

            if exploit.get().shift then
                delay = math.max(
                    1, buffer.delay or 1
                )
            end

            -- jitter delay (min/max): active with or without an exploit
            -- shift; the randomized threshold comes from update_jitter
            if buffer.jitter_delay ~= nil then
                delay = math.max(delay or 1, buffer.jitter_delay)
            end

            if delay ~= nil then
                delay_ticks = delay_ticks + 1

                if delay_ticks < delay then
                    return
                end
            end

            local should_invert = true

            if buffer.body_yaw == 'Jitter Random' then
                should_invert = utils.random_int(0, 1) == 0
            end

            inverts = inverts + 1

            if should_invert then
                inverted = not inverted
            end

            delay_ticks = 0
        end

        function buffer_mods:update_yaw_delay()
            -- L/R delays now gate the flip with or without an exploit shift
            -- (they previously only worked while DT / hideshots was shifting)
            local delay = nil

            if exploit.get().shift then
                delay = 1
            end

            local yaw_left_delay = nil
            local yaw_right_delay = nil

            if buffer.yaw_left_delay ~= nil or buffer.yaw_right_delay ~= nil then
                yaw_left_delay = buffer.yaw_left_delay or 1
                yaw_right_delay = buffer.yaw_right_delay or 1
            end

            if yaw_inverted and yaw_left_delay ~= nil then
                delay = yaw_left_delay
            end

            if not yaw_inverted and yaw_right_delay ~= nil then
                delay = yaw_right_delay
            end

            if delay ~= nil then
                yaw_delay_ticks = yaw_delay_ticks + 1

                if yaw_delay_ticks < delay then
                    return
                end
            end

            yaw_inverts = yaw_inverts + 1
            yaw_inverted = not yaw_inverted

            yaw_delay_ticks = 0
        end

        function buffer_mods:update_yaw_offset()
            if buffer.yaw_left ~= nil and buffer.yaw_right ~= nil then
                local yaw = buffer.yaw_offset or 0

                if buffer.yaw_left_delay ~= nil or buffer.yaw_right_delay ~= nil then
                    local body_yaw_offset = math.abs(buffer.body_yaw_offset)

                    if not yaw_inverted then
                        yaw = yaw + buffer.yaw_left
                    end

                    if yaw_inverted then
                        yaw = yaw + buffer.yaw_right
                    end

                    if not yaw_inverted then
                        body_yaw_offset = -body_yaw_offset
                    end

                    buffer.body_yaw = 'Static'
                    buffer.body_yaw_offset = body_yaw_offset
                else
                    if buffer.body_yaw_offset < 0 then
                        yaw = yaw + buffer.yaw_left
                    end

                    if buffer.body_yaw_offset > 0 then
                        yaw = yaw + buffer.yaw_right
                    end
                end

                buffer.yaw_offset = yaw
            end

            if buffer.yaw_offset ~= nil then
                buffer.yaw_offset = wrappers.normalize_yaw(buffer.yaw_offset)
            end
        end

        function buffer_mods:update_yaw_jitter()
            local jitter_inverts = inverts
            local jitter_inverted = inverted

            if buffer.yaw_left_delay ~= nil or buffer.yaw_right_delay ~= nil then
                jitter_inverts = yaw_inverts
                jitter_inverted = yaw_inverted
            end

            if buffer.yaw_jitter == 'Offset' then
                local yaw = buffer.yaw_offset or 0
                local offset = buffer.jitter_offset

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                buffer.yaw_offset = yaw + (jitter_inverted and offset or 0)

                return
            end

            if buffer.yaw_jitter == 'Center' then
                local yaw = buffer.yaw_offset or 0
                local offset = buffer.jitter_offset

                if not jitter_inverted then
                    offset = -offset
                end

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                buffer.yaw_offset = yaw + offset / 2

                return
            end

            if buffer.yaw_jitter == 'Skitter' then
                local index = jitter_inverts % #skitter
                local multiplier = skitter[index + 1]

                local yaw = buffer.yaw_offset or 0
                local offset = buffer.jitter_offset

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                buffer.yaw_offset = yaw + (offset * multiplier)

                return
            end

            if buffer.yaw_jitter == 'Sway' then
                -- smooth sinusoidal drift across [-offset, +offset]: the
                -- per-tick delta changes continuously, so detectors keyed on
                -- consistent alternation (FLIP/SPLIT-style) see no pattern,
                -- and yaw-history averaging tracks a position the body has
                -- already left. Cycle = full left-right-left period in ticks.
                local cycle = math.max(4, buffer.sway_cycle or 16)
                local ticks = localplayer.sent_packets or globals.tickcount()
                local phase = (ticks % cycle) / cycle

                local yaw = buffer.yaw_offset or 0
                local offset = buffer.jitter_offset

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                buffer.yaw_offset = yaw + offset * math.sin(phase * math.pi * 2)

                return
            end

            if buffer.yaw_jitter == 'Sequence' then
                local index = jitter_inverts % #sequence_steps
                local multiplier = sequence_steps[index + 1]

                local yaw = buffer.yaw_offset or 0
                local offset = buffer.jitter_offset

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                buffer.yaw_offset = yaw + (offset * multiplier)

                return
            end

            if buffer.yaw_jitter == 'X-way' then
                local ctx = buffer.way

                if ctx ~= nil then
                    local yaw = buffer.yaw_offset or 0
                    local offset = buffer.jitter_offset

                    local index = jitter_inverts % ctx.count
                    local is_custom = ctx.offsets ~= nil

                    if is_custom then
                        buffer.yaw_offset = yaw + ctx.offsets[index + 1]
                    end

                    if not is_custom then
                        buffer.yaw_offset = yaw + utils.lerp(
                            -offset, offset, index / (ctx.count - 1)
                        )
                    end
                end

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                return
            end
        end

        function buffer_mods:update_body_yaw()
            if buffer.body_yaw == 'Jitter' then
                local offset = buffer.body_yaw_offset

                if offset == 0 then
                    offset = 1
                end

                if not inverted then
                    offset = -offset
                end

                buffer.body_yaw = 'Static'
                buffer.body_yaw_offset = offset
            end

            if buffer.body_yaw == 'Jitter Random' then
                local offset = buffer.body_yaw_offset

                if offset == 0 then
                    offset = 1
                end

                buffer.body_yaw = 'Static'
                buffer.body_yaw_offset = inverted and offset or -offset
            end
        end
    end

    local defensive = { } do
        local function is_exploit_active()
            if reference.is_double_tap_active() then
                return true
            end

            if reference.is_on_shot_antiaim_active() then
                return true
            end

            return false
        end

        local default = { } do
            function default:update_pitch(buffer, items)
                local value = items.pitch:get()

                local pitch_offset_1 = items.pitch_offset_1:get()
                local pitch_offset_2 = items.pitch_offset_2:get()

                local pitch_offset_delay = items.pitch_offset_delay:get()
                local pitch_offset_speed = items.pitch_offset_speed:get()

                if value == 'Off' then
                    return
                end

                if value == 'Static' then
                    buffer.pitch = 'Custom'
                    buffer.pitch_offset = pitch_offset_1

                    return
                end

                if value == 'Switch' then
                    local delay = pitch_offset_delay

                    local offset = (localplayer.sent_packets % (delay * 2)) < delay
                        and pitch_offset_1 or pitch_offset_2

                    buffer.pitch = 'Custom'
                    buffer.pitch_offset = offset

                    return
                end

                if value == 'Spin' then
                    -- pitch Spin: continuous -89..+89 triangle sweep, rate
                    -- from the Speed slider. (the previous block here was a
                    -- hand-pasted copy of the YAW spin referencing a nil
                    -- global 'yaw_offset' -> arithmetic error every command,
                    -- which killed the whole setup_command chain and left NO
                    -- anti-aim applied during defensive ticks)
                    local speed = pitch_offset_speed

                    if speed <= 0 then
                        speed = 1
                    end

                    local cycle = (globals.curtime() * speed * 40) % 356

                    if cycle > 178 then
                        cycle = 356 - cycle
                    end

                    buffer.pitch = 'Custom'
                    buffer.pitch_offset = cycle - 89

                    return
                end

                if value == 'Random' then
                    buffer.pitch = 'Custom'

                    buffer.pitch_offset = utils.random_int(
                        pitch_offset_1, pitch_offset_2
                    )

                    return
                end
            end

            function default:update_yaw(buffer, items)
                local value = items.yaw:get()

                local yaw_offset = items.yaw_offset:get()

                local yaw_offset_1 = items.yaw_offset_1:get()
                local yaw_offset_2 = items.yaw_offset_2:get()

                -- Randomization: perturbs the stepped modes (Static / Switch /
                -- Left / Right) by +-N deg per command; Spin is continuous and
                -- Random already rolls, so they're left alone
                local yaw_random = 0

                if items.yaw_random_def ~= nil then
                    yaw_random = items.yaw_random_def:get()
                end

                local function randomize(offset)
                    if yaw_random > 0 then
                        offset = offset + utils.random_int(-yaw_random, yaw_random)
                    end

                    return offset
                end

                if value == 'Off' then
                    return
                end

                buffer.yaw_left = 0
                buffer.yaw_right = 0

                buffer.yaw_offset = 0

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                if value == 'Static' then
                    buffer.yaw = '180'
                    buffer.yaw_offset = randomize(yaw_offset)

                    return
                end

                if value == 'Switch' then
                    local delay = items.yaw_offset_delay:get()

                    local offset = localplayer.sent_packets % (delay * 2) < delay
                        and yaw_offset_1 or yaw_offset_2

                    buffer.yaw = '180'
                    buffer.yaw_offset = randomize(offset)

                    return
                end

                if value == 'Left / Right' then
                    -- independent Left / Right offsets (slider 1 = left,
                    -- slider 2 = right) so the two positions don't have to
                    -- mirror; each side held for Delay sent packets
                    local delay = math.max(1, items.yaw_offset_delay:get())
                    local stage = math.floor(localplayer.sent_packets / delay)

                    local offset = (stage % 2 == 0) and yaw_offset_1 or yaw_offset_2

                    buffer.yaw = '180'
                    buffer.yaw_offset = randomize(offset)

                    return
                end

                if value == 'Spin' then
                    local offset = globals.curtime() * (yaw_offset * 12) % 360

                    buffer.yaw = '180'
                    buffer.yaw_offset = offset

                    return
                end

                if value == 'Random' then
                    buffer.yaw = '180'

                    buffer.yaw_offset = utils.random_int(
                        yaw_offset_1, yaw_offset_2
                    )

                    return
                end
            end

            function default:update_body_yaw(buffer, items)
                if items.body_yaw_def == nil then
                    return
                end

                local value = items.body_yaw_def:get()

                -- 'Inherit' = keep the state builder's body yaw (the merge
                -- semantics of Buffer:copy already preserve it)
                if value == 'Inherit' then
                    return
                end

                if value == 'Off' then
                    buffer.body_yaw = 'Static'
                    buffer.body_yaw_offset = 0

                    return
                end

                -- 'Static' or 'Jitter'; Jitter is flipped downstream by
                -- buffer_mods:update_body_yaw like the builder's own
                buffer.body_yaw = value
                buffer.body_yaw_offset = items.body_yaw_offset_def:get()
            end

            function default:update(cmd, buffer, items)
                self:update_pitch(buffer, items)
                self:update_yaw(buffer, items)
                self:update_body_yaw(buffer, items)
            end
        end

        local flick = { }
        local flick_legit = { }

        do
            local freestand_side = 1

            local function get_angles(player, target)
                local player_origin = vector(entity.get_origin(player))
                local target_origin = vector(entity.get_origin(target))

                return vector((target_origin - player_origin):angles())
            end

            local function update_freestand(cmd)
                local me = entity.get_local_player()

                if me == nil then
                    return
                end

                local threat = client.current_threat()

                if threat == nil then
                    return
                end

                local angles = get_angles(me, threat)

                -- threat can despawn/go dormant between current_threat()
                -- and the hitbox read - vector(nil) would error
                local sx, sy, sz = entity.hitbox_position(threat, 3)

                if sx == nil then
                    return
                end

                local eye_pos = vector(utils.get_eye_position(me))
                local stomach = vector(sx, sy, sz)

                local forward_left = vector():init_from_angles(0, angles.y + 90)
                local forward_right = vector():init_from_angles(0, angles.y - 90)

                local point_left = eye_pos + forward_left * 31
                local point_right = eye_pos + forward_right * 31

                local ent_left, damage_left = client.trace_bullet(
                    me, point_left.x, point_left.y, point_left.z,
                    stomach.x, stomach.y, stomach.z, false
                )

                local ent_right, damage_right = client.trace_bullet(
                    me, point_right.x, point_right.y, point_right.z,
                    stomach.x, stomach.y, stomach.z, false
                )

                if ent_left ~= threat then
                    damage_left = 0
                end

                if ent_right ~= threat then
                    damage_right = 0
                end

                local should_update = (
                    (damage_left > 0 or damage_right > 0)
                    and damage_left ~= damage_right
                )

                if should_update then
                    freestand_side = (damage_left > damage_right) and -1 or 1
                end
            end

            function flick:update_yaw(buffer, items)
                buffer.yaw_base = 'At targets'

                buffer.yaw = '180'
                buffer.yaw_offset = items.yaw_offset_flick:get() * freestand_side

                buffer.yaw_left = 0
                buffer.yaw_right = 0

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0
            end

            function flick:update_body_yaw(buffer, items)
                buffer.body_yaw = 'Static'
                buffer.body_yaw_offset = freestand_side

                buffer.freestanding_body_yaw = false
            end

            function flick:update(cmd, buffer, items)
                update_freestand(cmd)

                default:update_pitch(buffer, items)

                self:update_yaw(buffer, items)
                self:update_body_yaw(buffer, items)

                buffer.edge_yaw = false

                buffer.roll = 0
            end

            function flick_legit:update(cmd, buffer, items)
                -- 'Flick Legit': the same freestand intelligence as Flick,
                -- dressed as a normal desync stand. Pitch is INHERITED from
                -- the state AA (no -89 chaos an observer would clock), the
                -- eye yaw stays near the target with a small cover-signed
                -- offset, and a saturated OPPOSITE body yaw keeps the normal
                -- desync silhouette. The unhittable part still comes from the
                -- defensive tickbase break plus the head sitting toward
                -- cover -- not from angles that read as "defensive spin".
                update_freestand(cmd)

                local offset = items.yaw_offset_flick_legit:get()

                buffer.yaw_base = 'At targets'

                buffer.yaw = '180'
                buffer.yaw_offset = offset * freestand_side
                    + utils.random_int(-6, 6)

                buffer.yaw_left = 0
                buffer.yaw_right = 0

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                buffer.body_yaw = 'Static'
                buffer.body_yaw_offset = -freestand_side * 180

                buffer.edge_yaw = false

                buffer.roll = 0
            end
        end

        function defensive:apply(cmd, items)
            if items.force_defensive ~= nil and items.force_defensive:get() then
                cmd.force_defensive = true
            end

            local is_duck_peek_active = reference.is_duck_peek_assist()

            if not is_exploit_active() or is_duck_peek_active then
                return false
            end

            local exploit_data = exploit.get()
            local defensive_data = exploit_data.defensive

            if defensive_data.left <= 0 then
                return
            end

            if not items.enabled:get() then
                return false
            end

            local buffer_ctx = { }

            if items.type:get() == 'Default' then
                default:update(cmd, buffer_ctx, items)
            end

            if items.type:get() == 'Flick' then
                flick:update(cmd, buffer_ctx, items)
            end

            if items.type:get() == 'Flick Legit' then
                flick_legit:update(cmd, buffer_ctx, items)
            end

            buffer.defensive = buffer_ctx

            return true
        end
    end

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
                    yaw = yaw + utils.random_int(-random, random)
                end

                buffer.yaw_offset = yaw
            end

            if buffer.yaw_type == 'Left / Right' then
                buffer.yaw = '180'

                local yaw_left = items.yaw_left_offset:get()
                local yaw_right = items.yaw_right_offset:get()

                local random_left = items.yaw_left_random:get()
                local random_right = items.yaw_right_random:get()

                -- local delay_left = items.yaw_left_delay:get()
                -- local delay_right = items.yaw_right_delay:get()

                -- local delay_second_left = items.yaw_left_delay_second:get()
                -- local delay_second_right = items.yaw_right_delay_second:get()

                if random_left > 0 then
                    yaw_left = yaw_left + utils.random_int(-random_left, random_left)
                end

                if random_right > 0 then
                    yaw_right = yaw_right + utils.random_int(-random_right, random_right)
                end

                buffer.yaw_left = yaw_left
                buffer.yaw_right = yaw_right

                local left_delays = 0
                local right_delays = 0

                for i = 1, 3 do
                    local list = items.yaw_left_delay[i]

                    if list == nil then
                        break
                    end

                    local delay = list.delay:get()
                    local min_delay = i == 1 and 1 or 0

                    if delay <= min_delay then
                        break
                    end

                    left_delays = left_delays + 1
                end

                for i = 1, 3 do
                    local list = items.yaw_right_delay[i]

                    if list == nil then
                        break
                    end

                    local delay = list.delay:get()
                    local min_delay = i == 1 and 1 or 0

                    if delay <= min_delay then
                        break
                    end

                    right_delays = right_delays + 1
                end

                local left_delay = nil
                local right_delay = nil

                local yaw_inverts = buffer_mods:get_yaw_inverts()
                local yaw_stage = math.floor(yaw_inverts / 2)

                -- Min / Max delay mode: randomize the side's hold time per
                -- flip instead of cycling the fixed step sliders
                if items.yaw_left_delay_mode ~= nil
                and items.yaw_left_delay_mode:get() == 'Min / Max' then
                    local delay_min = items.yaw_left_delay_min:get()
                    local delay_max = items.yaw_left_delay_max:get()

                    if delay_min > 0 or delay_max > 0 then
                        local low = math.max(1, delay_min)

                        left_delay = utils.random_int(low, math.max(low, delay_max))
                    end
                elseif left_delays > 0 then
                    local index = yaw_stage % left_delays
                    local list = items.yaw_left_delay[index + 1]

                    left_delay = list.delay:get()
                end

                if items.yaw_right_delay_mode ~= nil
                and items.yaw_right_delay_mode:get() == 'Min / Max' then
                    local delay_min = items.yaw_right_delay_min:get()
                    local delay_max = items.yaw_right_delay_max:get()

                    if delay_min > 0 or delay_max > 0 then
                        local low = math.max(1, delay_min)

                        right_delay = utils.random_int(low, math.max(low, delay_max))
                    end
                elseif right_delays > 0 then
                    local index = yaw_stage % right_delays
                    local list = items.yaw_right_delay[index + 1]

                    right_delay = list.delay:get()
                end

                buffer.yaw_left_delay = left_delay
                buffer.yaw_right_delay = right_delay
            end
        end

        local function update_jitter(items)
            if items.yaw_jitter == nil then
                return
            end

            local yaw_jitter = items.yaw_jitter:get()
            local jitter_offset = items.jitter_offset:get()

            if yaw_jitter ~= 'Off' then
                local random = items.jitter_random:get() * 0.01
                local random_offset = jitter_offset * random

                jitter_offset = jitter_offset + utils.random_int(
                    -random_offset, random_offset
                )
            end

            buffer.yaw_jitter = yaw_jitter
            buffer.jitter_offset = jitter_offset

            if yaw_jitter == 'Sway' and items.sway_cycle ~= nil then
                buffer.sway_cycle = items.sway_cycle:get()
            end

            -- jitter delay: hold each jitter phase for min..max sent packets;
            -- randomized per flip so the alternation period itself varies
            if items.jitter_delay_min ~= nil and items.jitter_delay_max ~= nil
            and yaw_jitter ~= 'Random' and yaw_jitter ~= 'Sway' then
                local delay_min = items.jitter_delay_min:get()
                local delay_max = items.jitter_delay_max:get()

                if delay_min > 0 or delay_max > 0 then
                    local low = math.max(1, delay_min)
                    local high = math.max(low, delay_max)

                    buffer.jitter_delay = utils.random_int(low, high)
                end
            end

            if yaw_jitter == 'X-way' then
                local way_ctx = { }

                way_ctx.count = items.x_way_ways:get()

                if items.jitter_x_way:get() == 'Custom' then
                    local offsets = { }

                    for i = 1, way_ctx.count do
                        offsets[i] = items['x_way_offset_' .. i]:get()
                    end

                    way_ctx.offsets = offsets
                end

                buffer.way = way_ctx
            end
        end

        local function update_body_yaw(items)
            if items.body_yaw == nil then
                return
            end

            local body_yaw = items.body_yaw:get()
            local body_yaw_offset = items.body_yaw_offset:get()

            local freestanding_body_yaw = false

            if body_yaw ~= 'Jitter' and body_yaw ~= 'Jitter Random' then
                freestanding_body_yaw = items.freestanding_body_yaw:get()
            end

            buffer.body_yaw = body_yaw
            buffer.body_yaw_offset = body_yaw_offset

            buffer.freestanding_body_yaw = freestanding_body_yaw

            if items.delay_from ~= nil and items.delay_to ~= nil then
                local delay_from = items.delay_from:get()
                local delay_to = items.delay_to:get()

                buffer.delay = delay_from

                if delay_from > 1 and delay_to > 0 then
                    buffer.delay = utils.random_int(
                        delay_from, delay_to
                    )
                end
            end
        end

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
                return false
            end

            self:apply_ex(items)
            return true, items
        end

        function builder:update(cmd)
            local states = conditions.get()
            local state = states[#states]

            if state == nil then
                return false, nil, nil
            end

            local active, items = self:apply(
                state
            )

            if not active or items == nil then
                local _, new_items = self:apply(
                    'Shared'
                )

                if new_items ~= nil then
                    items = new_items
                    state = 'Shared'
                end
            end

            return true, items, state
        end
    end

    local fakelag_clone = { } do
        local ref = menu_elements.antiaim.features.fakelag

        local HOTKEY_MODE = {
            [0] = 'Always on',
            [1] = 'On hotkey',
            [2] = 'Toggle',
            [3] = 'Off hotkey'
        }

        local function get_hotkey_value(_, mode, key)
            return HOTKEY_MODE[mode], key or 0
        end

        function fakelag_clone:update()
            override.set(reference.antiaim.fake_lag.enabled[1], ref.checkbox:get())
            override.set(reference.antiaim.fake_lag.enabled[2], get_hotkey_value(ref.hotkey:get()))

            override.set(reference.antiaim.fake_lag.amount, ref.type:get())

            override.set(reference.antiaim.fake_lag.variance, ref.variance:get())
            override.set(reference.antiaim.fake_lag.limit, ref.limit:get())
        end

        function fakelag_clone:shutdown()
            override.unset(reference.antiaim.fake_lag.enabled[1])
            override.unset(reference.antiaim.fake_lag.enabled[2])

            override.unset(reference.antiaim.fake_lag.amount)

            override.unset(reference.antiaim.fake_lag.variance)
            override.unset(reference.antiaim.fake_lag.limit)
        end
    end

    local safe_head = { } do
        local ref = menu_elements.antiaim.features.safe_head

        local function should_update()
            return ref.checkbox:get()
        end

        local function get_condition(me, threat)
            local weapon = entity.get_player_weapon(me)

            if weapon == nil then
                return nil
            end

            local weapon_info = csgo_weapons(weapon)

            if weapon_info == nil then
                return nil
            end

            local weapon_type = weapon_info.type
            local weapon_index = weapon_info.idx

            -- fun fact: taser is also a knife type of weapon
            local is_knife = weapon_type == 'knife'
            local is_taser = weapon_index == 31

            local my_origin = vector(entity.get_origin(me))
            local threat_origin = vector(entity.get_origin(threat))

            local delta = threat_origin - my_origin

            local height = -delta.z
            local distancesqr = delta:length2dsqr()

            if localplayer.is_onground then
                local is_distance_state = not localplayer.is_moving
                    or localplayer.is_crouched

                if is_distance_state and height >= 10 and distancesqr > 1000 * 1000 then
                    return 'Distance'
                end

                if localplayer.is_crouched then
                    if height >= 48 then
                        return 'Crouch'
                    end
                else
                    if not localplayer.is_moving and height >= 24 then
                        return 'Standing'
                    end
                end

                return nil
            end

            if localplayer.is_crouched then
                if is_taser and height > -20 and distancesqr < 500 * 500 then
                    return 'Air crouch taser'
                end

                if is_knife  then
                    return 'Air crouch knife'
                end

                if height > 160 then
                    return 'Air crouch'
                end
            end

            return nil
        end

        local function update_buffer(condition)
            if condition == 'Air crouch knife' then
                buffer.pitch = 'Default'
                buffer.yaw_base = 'At targets'

                buffer.yaw = '180'
                buffer.yaw_offset = 37

                buffer.yaw_left = 0
                buffer.yaw_right = 0

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0

                buffer.body_yaw = 'Static'
                buffer.body_yaw_offset = 1

                buffer.freestanding_body_yaw = false

                buffer.roll = 0
                buffer.defensive = nil

                return
            end

            buffer.pitch = 'Default'
            buffer.yaw_base = 'At targets'

            buffer.yaw = '180'
            buffer.yaw_offset = 0

            buffer.yaw_left = 0
            buffer.yaw_right = 0

            buffer.yaw_jitter = 'Off'
            buffer.jitter_offset = 0

            buffer.body_yaw = 'Static'
            buffer.body_yaw_offset = 0

            buffer.freestanding_body_yaw = false

            buffer.roll = 0
            buffer.defensive = nil
        end

        local function update_spam(cmd, condition)
            if not ref.options:get 'E Spam while active' then
                return
            end

            local buffer_ctx = { }

            buffer_ctx.pitch = 'Custom'
            buffer_ctx.pitch_offset = 0

            buffer_ctx.yaw = '180'
            buffer_ctx.yaw_offset = 180

            buffer_ctx.yaw_jitter = 'Off'
            buffer_ctx.jitter_offset = 0

            buffer_ctx.body_yaw = 'Static'
            buffer_ctx.body_yaw_offset = 180
            buffer_ctx.freestanding_body_yaw = false

            cmd.force_defensive = true

            buffer.defensive = buffer_ctx
        end

        function safe_head:update(cmd)
            if not should_update() then
                return false
            end

            local me = entity.get_local_player()

            if me == nil then
                return false
            end

            local threat = client.current_threat()

            if threat == nil  then
                return false
            end

            local condition = get_condition(me, threat)

            if condition == nil then
                return false
            end

            local is_enabled = ref.conditions:get(condition)

            if not is_enabled then
                return false
            end

            update_buffer(condition)
            update_spam(cmd, condition)

            return true
        end
    end

    local edge_yaw = { } do
        local ref = menu_elements.antiaim.features.edge_yaw

        local function get_state()
            if not localplayer.is_onground then
                return 'Air'
            end

            if localplayer.is_crouched then
                return 'Crouching'
            end

            if localplayer.is_moving then
                if reference.is_slow_motion() then
                    return 'Slow Walk'
                end

                return 'Moving'
            end

            return 'Standing'
        end

        local function is_disabled()
            return ref.disablers:get(
                get_state()
            )
        end

        local function is_enabled()
            if not ref.checkbox:get() then
                return false
            end

            if not ref.hotkey:get() then
                return false
            end

            return not is_disabled()
        end

        function edge_yaw:update(cmd)
            if not is_enabled() then
                buffer.edge_yaw = false

                return
            end

            buffer.edge_yaw = true
        end
    end

    local freestanding = { } do
        local ref = menu_elements.antiaim.features.freestanding

        local last_ack_defensive_side = nil
        local freestanding_side = nil

        local function is_value_near(value, target)
            return math.abs(target - value) <= 2.0
        end

        local function get_target_yaw(player)
            local threat = client.current_threat()

            if threat == nil then
                return nil
            end

            local player_origin = vector(
                entity.get_origin(player)
            )

            local threat_origin = vector(
                entity.get_origin(threat)
            )

            local delta = threat_origin - player_origin
            local _, yaw = delta:angles()

            return yaw - 180
        end

        local function get_approximated_side(yaw)
            if is_value_near(yaw, -90) then
                return -90
            end

            if is_value_near(yaw, 90) then
                return 90
            end

            return nil
        end

        local function get_side()
            local me = entity.get_local_player()

            if me == nil then
                return nil
            end

            local entity_data = c_entity(me)

            if entity_data == nil then
                return nil
            end

            local animstate = entity_data:get_anim_state()

            if animstate == nil then
                return nil
            end

            local target_yaw = get_target_yaw(me)

            if target_yaw == nil then
                return nil
            end

            return get_approximated_side(
                utils.normalize(animstate.eye_angles_y - target_yaw, -180, 180)
            )
        end

        local function get_state()
            if not localplayer.is_onground then
                return 'Air'
            end

            if localplayer.is_crouched then
                return 'Crouching'
            end

            if localplayer.is_moving then
                if reference.is_slow_motion() then
                    return 'Slow Walk'
                end

                return 'Moving'
            end

            return 'Standing'
        end

        local function is_disabled()
            return ref.disablers:get(
                get_state()
            )
        end

        local function is_enabled()
            if not ref.checkbox:get() then
                return false
            end

            if not ref.hotkey:get() then
                return false
            end

            return not is_disabled()
        end

        local function update_freestanding_options(cmd)
            local items = builder:get(
                'Freestanding'
            )

            -- respect the 'Override Freestanding' checkbox: the old check
            -- read items.override, a field that doesn't exist (the builder
            -- names it items.angles.enabled), so the checkbox was never
            -- consulted -- is_active_ex is the canonical gate
            if items ~= nil and not builder:is_active_ex(items) then
                items = nil
            end

            if freestanding_side ~= nil then
                buffer.pitch = 'Default'

                if items ~= nil then
                    builder:apply_ex(items)
                end
            end
        end

        function freestanding:update(cmd)
            if not is_enabled() then
                freestanding_side = nil
                return
            end

            if cmd.chokedcommands == 0 then
                freestanding_side = get_side()
            end

            buffer.freestanding = true
            update_freestanding_options(cmd)
        end
    end

    local manual_yaw = { } do
        local ref = menu_elements.antiaim.features.manual_yaw

        local current_dir = nil
        local hotkey_data = { }

        local dir_rotations = {
            ['left'] = -90,
            ['right'] = 90,
            ['forward'] = 180
        }

        local function handle_hotkey(item, dir)
            -- item:set 'On hotkey'

            local state = item:get()

            if hotkey_data[item.ref] == nil then
                hotkey_data[item.ref] = {
                    state = state,
                    last_time = 0
                }
            end

            local data = hotkey_data[item.ref]

            if ref.options:get 'Spam manuals' and dir ~= nil then
                local tick = globals.tickcount()

                if state and data.last_time < (tick - 11) then
                    if current_dir ~= dir then
                        current_dir = dir
                    else
                        current_dir = nil
                    end

                    data.last_time = tick
                end
            else
                if state and not data.state then
                    if current_dir ~= dir then
                        current_dir = dir
                    else
                        current_dir = nil
                    end
                end
            end

            data.state = state
        end

        local function on_paint_ui()
            handle_hotkey(ref.left, 'left')
            handle_hotkey(ref.right, 'right')
            handle_hotkey(ref.forward, 'forward')

            handle_hotkey(ref.reset, nil)
        end

        function manual_yaw:get()
            return current_dir
        end

        function manual_yaw:update(cmd, team)
            local angle = dir_rotations[
                current_dir
            ]

            if angle == nil then
                return false
            end

            buffer.enabled = true

            buffer.edge_yaw = false
            buffer.freestanding = false

            buffer.roll = 0

            buffer.defensive = nil

            if ref.options:get 'Disable yaw modifiers' then
                buffer.yaw_offset = 0

                buffer.yaw_left = 0
                buffer.yaw_right = 0

                buffer.yaw_left_delay = nil
                buffer.yaw_right_delay = nil

                buffer.yaw_jitter = 'Off'
                buffer.jitter_offset = 0
            end

            if ref.options:get 'Freestanding body' then
                buffer.yaw_left_delay = nil
                buffer.yaw_right_delay = nil

                buffer.body_yaw = 'Static'
                buffer.body_yaw_offset = 180
                buffer.freestanding_body_yaw = true
            end

            builder:apply 'Manual AA'

            local yaw = buffer.yaw_offset or 0

            buffer.yaw_base = 'Local view'
            buffer.yaw_offset = yaw + angle

            return true
        end

        local callbacks do
            local function on_enabled(item)
                local value = item:get()

                if not value then
                    current_dir = nil
                end

                utils.event_callback('paint_ui', on_paint_ui, value)
            end

            ref.checkbox:set_callback(
                on_enabled, true
            )
        end
    end

    local avoid_backstab = { } do
        local ref = menu_elements.antiaim.features.avoid_backstab

        local function is_weapon_knife(weapon)
            local weapon_info = csgo_weapons(weapon)

            if weapon_info == nil then
                return false
            end

            -- is weapon taser
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

    local break_lc_triggers = { } do
        local ref = menu_elements.antiaim.features.break_lc_triggers

        local ACT_CSGO_RELOAD = 967

        local GetClientEntity = vtable_bind(
            'client.dll', 'VClientEntityList003',
            3, 'uint32_t(__thiscall*)(void*, int)'
        )

        local m_flFlashDuration = 0x10470 -- dumped nervar
        local m_flFlashBangTime = m_flFlashDuration - 0x10

        local function get_flashbang_time(player)
            if player == nil then
                return nil
            end

            local address = GetClientEntity(player)

            if address == nil then
                return nil
            end

            return ffi.cast('float*', address + m_flFlashBangTime)[0]
        end

        local function get_reload_time(player)
            if player == nil then
                return nil
            end

            local player_info = c_entity(player)

            if player_info == nil then
                return nil
            end

            local anim_layer = player_info:get_anim_overlay(1)

            if anim_layer == nil or anim_layer.entity == nil then
                return nil
            end

            local activity = player_info:get_sequence_activity(
                anim_layer.sequence
            )

            if activity ~= ACT_CSGO_RELOAD then
                return nil
            end

            if anim_layer.weight == 0 then
                return nil
            end

            return anim_layer.cycle
        end

        local function get_flinch(player)
            if player == nil then
                return nil
            end

            local player_info = c_entity(player)

            if player_info == nil then
                return nil
            end

            local anim_layer = player_info:get_anim_overlay(10)

            if anim_layer == nil then
                return nil
            end

            return anim_layer.weight
        end

        local function is_flashed(player)
            local flash_time = get_flashbang_time(player)

            return flash_time ~= nil
                and flash_time > 0
        end

        local function is_reloading(player)
            return get_reload_time(player) ~= nil
        end

        local function is_taking_damage(player)
            local flinch = get_flinch(player)

            return flinch ~= nil
                and flinch ~= 0
        end

        local function should_update()
            if not ref.checkbox:get() then
                return false
            end

            local me = entity.get_local_player()

            if me == nil then
                return false
            end

            if ref.states:get 'Flashed' and is_flashed(me) then
                return true
            end

            if ref.states:get 'Reloading' and is_reloading(me) then
                return true
            end

            if ref.states:get 'Taking damage' and is_taking_damage(me) then
                return true
            end

            return false
        end

        function break_lc_triggers:update(cmd)
            if not should_update() then
                return
            end

            cmd.force_defensive = 1
        end
    end

   local vanish_mode = { } do
    local ref = menu_elements.antiaim.features.vanish

    local function are_enemies_dead()
        local me = entity.get_local_player()

        if me == nil then
            return false
        end

        local my_team = entity.get_prop(me, 'm_iTeamNum')
        local player_resource = entity.get_player_resource()

        for i = 1, globals.maxplayers() do
            local is_connected = entity.get_prop(
                player_resource, 'm_bConnected', i
            )

            if is_connected ~= 1 then
                goto continue
            end

            local player_team = entity.get_prop(
                player_resource, 'm_iTeam', i
            )

            if me == i or player_team == my_team then
                goto continue
            end

            local is_alive = entity.get_prop(
                player_resource, 'm_bAlive', i
            )

            if is_alive == 1 then
                return false
            end

            ::continue::
        end

        return true
    end

    local function should_update()
        local game_rules = entity.get_game_rules()

        if game_rules == nil then
            return false
        end

        local warmup_period = entity.get_prop(
            game_rules, 'm_bWarmupPeriod'
        )

        if ref:get 'On Warmup' and warmup_period == 1 then
            return true
        end

        if ref:get 'No Enemies' and are_enemies_dead() then
            return true
        end

        return false
    end

function vanish_mode:update()
    if ref:get() == nil then
        return false
    end

    if not should_update() then
        return false
    end

    buffer.enabled = true

    buffer.pitch = 'Custom'
    buffer.pitch_offset = 0

    buffer.yaw = '180'
    buffer.yaw_offset = (globals.curtime() * 300) % 360

    -- Clear any yaw side values that might have randomization
    buffer.yaw_left = 0
    buffer.yaw_right = 0
    
    -- Clear any delay values
    buffer.yaw_left_delay = nil
    buffer.yaw_right_delay = nil

    buffer.yaw_jitter = 'Off'
    buffer.jitter_offset = 0

    buffer.body_yaw = 'Static'
    buffer.body_yaw_offset = 1

    buffer.freestanding_body_yaw = false

    buffer.defensive = nil

    buffer.edge_yaw = false
    buffer.freestanding = false

    return true
end
end


    local function update_antiaim(cmd)
        fakelag_clone:update()

        local active, items = builder:update(cmd)

        break_lc_triggers:update(cmd)

        if manual_yaw:update(cmd) then
            return
        end

        if avoid_backstab:update() then
            return
        end

        if active and items ~= nil and items.defensive ~= nil then
            defensive:apply(cmd, items.defensive)
        end

        edge_yaw:update(cmd)
        freestanding:update(cmd)

        if not safe_head:update(cmd) then
            -- SISKI
        end

        vanish_mode:update()
    end

    -- defensive verification HUD: lights up ONLY when the defensive buffer
    -- is genuinely copied onto a command, straight from the apply path --
    -- ground truth, not menu state
    local ui_def_indicator = ui.new_checkbox('LUA', 'B', 'Defensive AA indicator')
    local def_hud = { last = -1000, yaw = 0, pitch = 0, left = 0 }

    local function update_defensive(cmd)
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

        -- the defensive buffer owns the yaw completely: the state's L/R hold
        -- delays must not gate the defensive flip cadence or force the body
        -- yaw sign in update_yaw_offset (Buffer:copy merges, so nil fields
        -- in the defensive ctx can't clear these - do it explicitly)
        if list.yaw_left ~= nil then
            buffer.yaw_left_delay = nil
            buffer.yaw_right_delay = nil
        end

        def_hud.last = globals.tickcount()
        def_hud.left = defensive.left
        def_hud.yaw = list.yaw_offset or 0
        def_hud.pitch = list.pitch_offset or 0
    end

    local function update_buffer(cmd)
        update_defensive(cmd)

        if cmd.chokedcommands == 0 then
            buffer_mods:update_inverter()
            buffer_mods:update_yaw_delay()
        end

        buffer_mods:update_body_yaw()
        buffer_mods:update_yaw_jitter()
        buffer_mods:update_yaw_offset()
    end

    local function on_shutdown()
        fakelag_clone:shutdown()
        buffer:unset()
    end

    local function on_pre_config_save()
        fakelag_clone:shutdown()
        buffer:unset()
    end

    local function on_setup_command(cmd)
        buffer:clear()
        buffer:unset()

        update_antiaim(cmd)
        update_buffer(cmd)

        buffer:set()
    end

    utils.event_callback('shutdown', on_shutdown)
    utils.event_callback('pre_config_save', on_pre_config_save)
    utils.event_callback('setup_command', on_setup_command)

    client.set_event_callback('paint', function()
        if not ui.get(ui_def_indicator) then
            return
        end

        local sw, sh = client.screen_size()

        -- menu-state debug: live native value vs wrapper cache for the two
        -- checkboxes that refuse to tick. live=true cache=false -> broken
        -- callback bridge (resync heals it); live=false after clicking ->
        -- the click never lands (menu geometry)
        if ui.is_menu_open() then
            local fs = menu_elements.antiaim.features.freestanding.checkbox
            local my = menu_elements.antiaim.features.manual_yaw.checkbox

            renderer.text(
                sw / 2, sh - 70, 255, 220, 100, 230, 'cb', 0,
                string.format(
                    'fs live:%s cache:%s   my live:%s cache:%s',
                    tostring(ui.get(fs.ref)), tostring(fs:get()),
                    tostring(ui.get(my.ref)), tostring(my:get())
                )
            )
        end

        local age = globals.tickcount() - def_hud.last
        local active = age <= 2

        if active then
            renderer.text(
                sw / 2, sh - 45, 60, 255, 110, 230, 'cb', 0,
                string.format(
                    'DEFENSIVE  yaw %+.0f  pitch %+.0f  (%d ticks left)',
                    def_hud.yaw, def_hud.pitch, def_hud.left
                )
            )
        else
            renderer.text(
                sw / 2, sh - 45, 140, 140, 140, 160, 'cb', 0,
                'defensive idle'
            )
        end
    end)
end

local watermark = { } do
    local function on_paint()
        local screen_width, screen_height = client.screen_size()
        local text = "kamibebra"
        local x = screen_width / 2
        local y = screen_height - 25
        
        renderer.text(x, y, 255, 255, 255, 200, "cb", 0, text)
    end

    client.set_event_callback('paint', on_paint)
end
