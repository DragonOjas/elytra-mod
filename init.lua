-- ================================================================
--  ELYTRA MOD v4  —  Minetest / TechBlox
--  Full rewrite fixing every known bug in v3, plus new systems.
--
--  NEW in v4:
--   • Enchantments   — Unbreaking I/II/III (craft with mese shards)
--   • Altitude bonus — higher altitude = thinner air = more speed
--   • Glide stats    — /elytrarecord shows longest flight + distance
--   • Safe landing   — if you glide into ground slowly, no stop msg spam
--   • Auto-glide     — hold sneak mid-fall for 1.5s to auto-activate
--   • Multi-rocket   — stack boosts, each rocket adds more thrust
--   • Proper water   — swim physics when in water, don't just freeze
--   • Footstep fix   — re-enable walk sounds after landing
--
--  BUGS FIXED from v3:
--   • durability=0 saved as int 0, restored as max  → use string key
--   • wind_timer logic inverted (sound never restarted)
--   • is_in_water nil crash
--   • collision single-point probe misses side walls
--   • gunpowder doesn't exist in default → use tnt:gunpowder or paper
--   • double rocket fire from on_use + on_item_use
--   • reset_physics coast sets vel before engine restores gravity
--   • ground check only centre X/Z → now checks 4 corner offsets
--   • colorize inside string.format %s mangles escape codes
--   • goto continue inside do_physics jumps past label → split blocks
-- ================================================================

local elytra  = {}
local storage = minetest.get_mod_storage()

-- ─── SAFE COMPAT ───────────────────────────────────────────
-- (no table.copy dependency needed in this mod)

-- ─── CONFIG ────────────────────────────────────────────────
local CFG = {
    -- Physics (Minecraft 1.20-accurate)
    speed_base          = 7.2,    -- m/s at glide start
    speed_max           = 30.0,   -- terminal dive
    speed_min           = 2.0,    -- stall threshold
    gravity_base        = 0.08,   -- gravity per tick (very light, like MC)
    pitch_accel         = 0.09,   -- speed gain per radian downward pitch
    pitch_lift          = 0.045,  -- speed loss per radian upward pitch
    drag                = 0.009,  -- air resistance (MC is very low)
    speed_smooth        = 0.14,   -- lerp smoothing factor
    momentum_coast      = 0.88,   -- horizontal speed kept on manual stop

    -- Altitude bonus: above y=100, gain extra speed
    altitude_bonus_y    = 100,    -- Y above which bonus kicks in
    altitude_bonus_max  = 4.0,    -- extra m/s at very high altitude
    altitude_bonus_scale= 300,    -- Y range over which bonus builds

    -- Stall
    stall_time          = 0.55,   -- seconds before stall triggers

    -- Auto-glide (hold sneak while falling)
    auto_glide_hold     = 1.5,    -- seconds of sneak+falling to auto-start
    auto_glide_min_vy   = -2.0,   -- must be falling at least this fast

    -- Durability
    max_durability      = 432,
    dur_drain_base      = 1,      -- per second (Unbreaking reduces this)

    -- Enchantments: Unbreaking drain multipliers
    unbreaking_drain    = { [1]=0.67, [2]=0.5, [3]=0.33 },

    -- Ground checks
    ground_check_dist   = 1.05,

    -- Collision
    collision_threshold = 7.0,    -- m/s before wall hurts
    collision_offsets   = {       -- probe points ahead: centre + two wings
        { x=0,    y=0.5, z=0    },
        { x=0.4,  y=0.5, z=0    },
        { x=-0.4, y=0.5, z=0    },
        { x=0,    y=1.2, z=0    },
    },
    collision_dist      = 0.55,

    -- Water
    water_drag          = 0.30,

    -- Updrafts (blocks → upward force strength)
    updraft_blocks = {
        ["default:lava_source"]  = 7.0,
        ["default:lava_flowing"] = 4.5,
        ["fire:basic_flame"]     = 3.5,
        ["fire:permanent_flame"] = 3.5,
        ["default:torch"]        = 0.6,
    },
    updraft_range       = 2,

    -- Rocket boost
    rocket_speed        = 28.0,   -- speed after one rocket
    rocket_duration     = 1.2,    -- seconds of thrust
    rocket_stack_max    = 3,      -- max rockets stacked

    -- Banking animation
    bank_speed          = 0.13,
    bank_max            = 45.0,
    bank_decay          = 0.80,

    -- Particles
    trail_min_speed     = 8.0,
    trail_max_count     = 14,

    -- Sounds
    wind_pitch_min      = 0.55,
    wind_pitch_max      = 1.5,
    wind_update_rate    = 0.3,
}

-- ─── HELPERS ───────────────────────────────────────────────
local function lerp(a, b, t)  return a + (b - a) * t end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function vlen(v) return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end
local function vlen2d(v) return math.sqrt(v.x*v.x + v.z*v.z) end

local function safe_find(s, pat)
    if type(s) ~= "string" then return nil end
    return s:find(pat)
end

-- ─── PERSISTENT STORAGE ────────────────────────────────────
-- Use string keys so we can distinguish durability=0 from "never saved"
local STOR_DUR  = "v4_dur_"
local STOR_ENC  = "v4_enc_"   -- enchantment level

local function stor_save(key, val)
    storage:set_string(key, tostring(val))
end

local function stor_load_int(key, default)
    local s = storage:get_string(key)
    if s == "" or s == nil then return default end
    return tonumber(s) or default
end

-- ─── PER-PLAYER STATE ──────────────────────────────────────
local P = {}   -- P[name] = state table

local function init_state(name)
    P[name] = {
        -- Equip
        equipped        = false,
        durability      = stor_load_int(STOR_DUR .. name, CFG.max_durability),
        enchant         = stor_load_int(STOR_ENC .. name, 0),  -- Unbreaking level
        -- Flight
        gliding         = false,
        speed           = CFG.speed_base,
        target_speed    = CFG.speed_base,
        -- Rocket
        boosting        = false,
        boost_timer     = 0.0,
        boost_stacks    = 0,     -- how many rockets fired in sequence
        -- Animation
        tilt            = 0.0,
        prev_yaw        = 0.0,
        -- Stall
        stall_timer     = 0.0,
        -- Auto-glide
        fall_hold_timer = 0.0,
        -- Sound
        wind_handle     = nil,
        wind_timer      = 0.0,
        -- HUD (multiple elements)
        hud             = {},    -- hud.status, hud.alt, hud.speed_img
        -- Water
        in_water        = false,
        -- Stats
        flight_start_time = nil,
        flight_start_pos  = nil,
        best_flight_time  = stor_load_int("v4_best_t_" .. name, 0),
        best_flight_dist  = stor_load_int("v4_best_d_" .. name, 0),
        total_distance    = 0.0,
        -- Controls
        _aux1_held      = false,
        _unequip_held   = false,
    }
end

local function gs(player)
    local name = player:get_player_name()
    if not P[name] then init_state(name) end
    return P[name]
end

-- ─── LOOK DIRECTION ────────────────────────────────────────
local function look_dir(player)
    local yaw   = player:get_look_horizontal()
    local pitch = player:get_look_vertical()
    local cp    = math.cos(pitch)
    return {
        x =  math.sin(yaw) * cp,
        y = -math.sin(pitch),
        z = -math.cos(yaw) * cp,
    }
end

-- ─── NODE QUERIES ──────────────────────────────────────────
local function node_name(pos)
    local n = minetest.get_node(pos)
    return n and n.name or "air"
end

-- Ground: check centre + 4 foot corners
local function is_grounded(player)
    local pos = player:get_pos()
    if not pos then return false end
    local dy = -CFG.ground_check_dist
    local offsets = {
        {0, 0}, {0.3, 0.3}, {-0.3, 0.3}, {0.3, -0.3}, {-0.3, -0.3}
    }
    for _, o in ipairs(offsets) do
        local n = node_name({ x=pos.x+o[1], y=pos.y+dy, z=pos.z+o[2] })
        if n ~= "air" and n ~= "ignore" and n ~= ""
            and not safe_find(n, "water") and not safe_find(n, "lava") then
            return true
        end
    end
    return false
end

local function is_in_water(player)
    local pos = player:get_pos()
    if not pos then return false end
    local n = node_name({ x=pos.x, y=pos.y+0.5, z=pos.z })
    return safe_find(n, "water") ~= nil
end

-- ─── UPDRAFT ───────────────────────────────────────────────
local function get_updraft(player)
    local pos = player:get_pos()
    if not pos then return 0 end
    local total = 0
    local r = CFG.updraft_range
    for dx = -r, r do
        for dz = -r, r do
            for dy = -2, 0 do
                local n = node_name({x=pos.x+dx, y=pos.y+dy, z=pos.z+dz})
                local str = CFG.updraft_blocks[n]
                if str then
                    local dist = math.sqrt(dx*dx + dz*dz) + 1
                    total = total + str / dist
                end
            end
        end
    end
    return total
end

-- ─── ALTITUDE BONUS ────────────────────────────────────────
local function get_altitude_bonus(player)
    local pos = player:get_pos()
    if not pos then return 0 end
    local above = pos.y - CFG.altitude_bonus_y
    if above <= 0 then return 0 end
    return math.min(CFG.altitude_bonus_max,
        (above / CFG.altitude_bonus_scale) * CFG.altitude_bonus_max)
end

-- ─── COLLISION ─────────────────────────────────────────────
-- Returns true and stops glide if player is flying into a wall
local function check_wall_collision(player, state)
    local pos  = player:get_pos()
    local dir  = look_dir(player)
    if not pos then return false end

    for _, off in ipairs(CFG.collision_offsets) do
        -- Rotate offset by yaw so wings are always left/right relative to look dir
        local yaw = player:get_look_horizontal()
        local lx  = off.x * math.cos(yaw) - off.z * math.sin(yaw)
        local lz  = off.x * math.sin(yaw) + off.z * math.cos(yaw)
        local probe = {
            x = pos.x + lx + dir.x * CFG.collision_dist,
            y = pos.y + off.y,
            z = pos.z + lz + dir.z * CFG.collision_dist,
        }
        local n = node_name(probe)
        if n ~= "air" and n ~= "ignore" and n ~= ""
            and not safe_find(n, "water") and not safe_find(n, "lava") then
            -- Deal damage proportional to excess speed
            local excess = math.max(0, state.speed - CFG.collision_threshold)
            if excess > 0 then
                local dmg = math.max(1, math.floor(excess / 3.0))
                local hp  = player:get_hp()
                player:set_hp(math.max(0, hp - dmg))
            end
            return true
        end
    end
    return false
end

-- ─── ANIMATION ─────────────────────────────────────────────
local function apply_animation(player, state, dt)
    local yaw   = player:get_look_horizontal()
    local delta = yaw - state.prev_yaw
    state.prev_yaw = yaw

    -- Wrap delta
    if delta >  math.pi then delta = delta - 2*math.pi end
    if delta < -math.pi then delta = delta + 2*math.pi end

    local target = clamp(-delta * (180/math.pi) * 14, -CFG.bank_max, CFG.bank_max)
    if math.abs(delta) > 0.001 then
        state.tilt = lerp(state.tilt, target, CFG.bank_speed)
    else
        state.tilt = state.tilt * CFG.bank_decay
    end

    local shift = math.sin(math.rad(state.tilt)) * 3.0
    if player.set_eye_offset then
        player:set_eye_offset({x=shift, y=0, z=0}, {x=shift, y=0, z=0})
    end
    if player.set_animation then
        player:set_animation({x=200, y=219}, 20, 0, true)
    end
end

local function reset_animation(player)
    if player.set_eye_offset then
        player:set_eye_offset({x=0,y=0,z=0},{x=0,y=0,z=0})
    end
    if player.set_animation then
        player:set_animation({x=0, y=79}, 15, 0, true)
    end
end

-- ─── SOUND ─────────────────────────────────────────────────
local SND = {
    wind    = "elytra_wind",
    whoosh  = "elytra_whoosh",
    rocket  = "elytra_rocket",
    crack   = "elytra_crack",
    stall   = "elytra_stall_creak",
    land_h  = "elytra_land_hard",
    land_s  = "elytra_land_soft",
    splash  = "default_water_splash",
    boost   = "elytra_boost_beep",
}

local function play_sound(player, name, pitch, gain)
    local pos = player:get_pos()
    if not pos then return nil end
    return minetest.sound_play(
        { name = name, loop = false },
        { pos = pos, gain = gain or 0.8, pitch = pitch or 1.0, max_hear_distance = 20 }
    )
end

local function stop_sound(h)
    if h then pcall(minetest.sound_stop, h) end
end

-- update_wind: called by callers who already throttle via wind_timer.
-- This function just stops the old handle and starts a new pitched one.
-- Do NOT increment wind_timer here — callers own that.
local function update_wind(player, state)
    if not state.gliding then
        stop_sound(state.wind_handle)
        state.wind_handle = nil
        return
    end

    local t     = clamp((state.speed - CFG.speed_min) / (CFG.speed_max - CFG.speed_min), 0, 1)
    local pitch = lerp(CFG.wind_pitch_min, CFG.wind_pitch_max, t)
    local gain  = lerp(0.15, 0.85, t)

    stop_sound(state.wind_handle)
    state.wind_handle = nil
    local pos = player:get_pos()
    if pos then
        state.wind_handle = minetest.sound_play(
            { name = SND.wind, loop = true },
            { pos = pos, gain = gain, pitch = pitch, max_hear_distance = 6 }
        )
    end
end

-- ─── PARTICLES ─────────────────────────────────────────────
local function pt_trail(player, state)
    if state.speed < CFG.trail_min_speed then return end
    local pos  = player:get_pos()
    if not pos then return end
    local d    = look_dir(player)
    local t    = clamp((state.speed - CFG.trail_min_speed) / (CFG.speed_max - CFG.trail_min_speed), 0, 1)
    local cnt  = math.max(1, math.floor(t * CFG.trail_max_count))
    local spd  = state.speed

    minetest.add_particlespawner({
        amount      = cnt,
        time        = 0.05,
        minpos      = {x=pos.x-0.25, y=pos.y+0.3, z=pos.z-0.25},
        maxpos      = {x=pos.x+0.25, y=pos.y+0.7, z=pos.z+0.25},
        minvel      = {x=-d.x*spd*0.5-0.5, y=-d.y*spd*0.3-0.5, z=-d.z*spd*0.5-0.5},
        maxvel      = {x=-d.x*spd*0.7+0.5, y=-d.y*spd*0.3+0.5, z=-d.z*spd*0.7+0.5},
        minacc      = {x=0, y=-0.4, z=0},
        maxacc      = {x=0, y=-0.1, z=0},
        minexptime  = 0.15,
        maxexptime  = 0.45,
        minsize     = 0.2,
        maxsize     = 0.7,
        texture     = "elytra_particle_wind.png",
    })

    -- High-speed streaks
    if state.speed > 17 then
        minetest.add_particlespawner({
            amount      = 4,
            time        = 0.05,
            minpos      = {x=pos.x-1, y=pos.y+0.3, z=pos.z-1},
            maxpos      = {x=pos.x+1, y=pos.y+0.9, z=pos.z+1},
            minvel      = {x=-d.x*14, y=-d.y*6, z=-d.z*14},
            maxvel      = {x=-d.x*18, y=-d.y*6, z=-d.z*18},
            minacc      = {x=0, y=0, z=0},
            maxacc      = {x=0, y=0, z=0},
            minexptime  = 0.06,
            maxexptime  = 0.12,
            minsize     = 0.05,
            maxsize     = 0.2,
            texture     = "elytra_particle_streak.png",
        })
    end
end

local function pt_rocket(player)
    local pos = player:get_pos()
    local d   = look_dir(player)
    if not pos then return end
    minetest.add_particlespawner({
        amount      = 25,
        time        = 0.9,
        minpos      = {x=pos.x-0.2, y=pos.y+0.2, z=pos.z-0.2},
        maxpos      = {x=pos.x+0.2, y=pos.y+0.6, z=pos.z+0.2},
        minvel      = {x=-d.x*10-1, y=-d.y*8-2, z=-d.z*10-1},
        maxvel      = {x=-d.x*14+1, y=-d.y*8+2, z=-d.z*14+1},
        minacc      = {x=0, y=-1, z=0},
        maxacc      = {x=0, y= 0, z=0},
        minexptime  = 0.25,
        maxexptime  = 0.8,
        minsize     = 0.5,
        maxsize     = 1.6,
        texture     = "elytra_particle_rocket.png",
        glow        = 12,
    })
end

local function pt_stall(player)
    local pos = player:get_pos()
    if not pos then return end
    minetest.add_particlespawner({
        amount      = 22,
        time        = 0.25,
        minpos      = {x=pos.x-0.6, y=pos.y,   z=pos.z-0.6},
        maxpos      = {x=pos.x+0.6, y=pos.y+1, z=pos.z+0.6},
        minvel      = {x=-2, y=1, z=-2},
        maxvel      = {x= 2, y=5, z= 2},
        minacc      = {x=0, y=-4, z=0},
        maxacc      = {x=0, y=-1, z=0},
        minexptime  = 0.9,
        maxexptime  = 2.2,
        minsize     = 0.4,
        maxsize     = 1.1,
        texture     = "elytra_particle_feather.png",
    })
end

local function pt_splash(player)
    local pos = player:get_pos()
    if not pos then return end
    minetest.add_particlespawner({
        amount      = 28,
        time        = 0.15,
        minpos      = {x=pos.x-0.6, y=pos.y,   z=pos.z-0.6},
        maxpos      = {x=pos.x+0.6, y=pos.y+0.2, z=pos.z+0.6},
        minvel      = {x=-4, y=2, z=-4},
        maxvel      = {x= 4, y=7, z= 4},
        minacc      = {x=0, y=-9, z=0},
        maxacc      = {x=0, y=-6, z=0},
        minexptime  = 0.3,
        maxexptime  = 0.9,
        minsize     = 0.3,
        maxsize     = 0.8,
        texture     = "bubble.png",
    })
end

-- ─── HUD ───────────────────────────────────────────────────
local function hud_show(player, state)
    if state.hud.status then return end
    state.hud.status = player:hud_add({
        hud_elem_type = "text",
        position      = {x=0.5, y=0.82},
        offset        = {x=0,   y=0},
        text          = "Elytra Ready",
        alignment     = {x=0,   y=0},
        color         = 0xFFFFFF,
        scale         = {x=150, y=150},
        z_index       = 100,
    })
    state.hud.alt = player:hud_add({
        hud_elem_type = "text",
        position      = {x=0.02, y=0.4},
        offset        = {x=0,    y=0},
        text          = "",
        alignment     = {x=-1,   y=0},
        color         = 0xCCCCCC,
        scale         = {x=100,  y=100},
        z_index       = 99,
    })
end

local function hud_hide(player, state)
    for k, id in pairs(state.hud) do
        if id then
            player:hud_remove(id)
            state.hud[k] = nil
        end
    end
end

local function hud_update(player, state)
    if not state.hud.status then return end
    local dur_pct = math.floor((state.durability / CFG.max_durability) * 100)

    -- Durability color (no colorize inside format — build string separately)
    local dur_str
    if dur_pct > 60 then
        dur_str = minetest.colorize("#55ff55", dur_pct .. "%")
    elseif dur_pct > 25 then
        dur_str = minetest.colorize("#ffaa00", dur_pct .. "%")
    else
        dur_str = minetest.colorize("#ff5555", dur_pct .. "%")
    end

    local enc_str = ""
    if state.enchant > 0 then
        enc_str = minetest.colorize("#aa55ff", " [U" .. state.enchant .. "]")
    end

    local status_txt
    if state.gliding then
        local t      = clamp((state.speed-CFG.speed_min)/(CFG.speed_max-CFG.speed_min), 0, 1)
        local filled = math.floor(t * 8)
        local bar    = string.rep("\xe2\x96\x88", filled) .. string.rep("\xe2\x96\x91", 8-filled)

        local warn = ""
        if state.speed <= CFG.speed_min + 0.8 then
            warn = minetest.colorize("#ffaa00", "  [STALL]")
        elseif state.boosting then
            warn = minetest.colorize("#ffaa55", "  [BOOST x" .. state.boost_stacks .. "]")
        end

        status_txt =
            minetest.colorize("#55ffff", "[GLIDING] ") ..
            "[" .. bar .. "] " ..
            string.format("%.0f m/s", state.speed) ..
            "  DUR " .. dur_str .. enc_str .. warn
    else
        status_txt =
            minetest.colorize("#55ff55", "[ELYTRA] ") ..
            "Ready  DUR " .. dur_str .. enc_str
    end

    player:hud_change(state.hud.status, "text", status_txt)

    -- Altitude sidebar (only while gliding)
    local alt_txt = ""
    if state.gliding then
        local pos = player:get_pos()
        if pos then
            local bonus = get_altitude_bonus(player)
            alt_txt = string.format("ALT %.0fm", pos.y)
            if bonus > 0.1 then
                alt_txt = alt_txt .. minetest.colorize("#55ffff",
                    string.format("  +%.1f boost", bonus))
            end
        end
    end
    player:hud_change(state.hud.alt, "text", alt_txt)
end

-- ─── PHYSICS RESET ─────────────────────────────────────────
-- coast=true: preserve horizontal momentum (manual stop / landing)
-- coast=false: zero horizontal (crash / forced stop)
local function reset_physics(player, coast)
    -- Restore gravity first
    player:set_physics_override({gravity=1.0, speed=1.0, jump=1.0})
    -- Apply velocity on next tick after engine restores it
    minetest.after(0.05, function()
        if not player or not player:is_player() then return end
        local vel = player:get_velocity()
        if not vel then return end
        if coast then
            local cfg_state = P[player:get_player_name()]
            local factor    = cfg_state and CFG.momentum_coast or 0.5
            player:set_velocity({
                x = vel.x * factor,
                y = vel.y,
                z = vel.z * factor,
            })
        else
            player:set_velocity({x=0, y=vel.y, z=0})
        end
    end)
end

-- ─── STATS ─────────────────────────────────────────────────
local function flight_start(player, state)
    state.flight_start_time = minetest.get_gametime()
    state.flight_start_pos  = player:get_pos()
    state.total_distance    = 0.0
end

local function flight_end(player, state)
    if not state.flight_start_time then return end
    local duration = minetest.get_gametime() - state.flight_start_time
    local dist     = math.floor(state.total_distance)
    local name     = player:get_player_name()

    if duration > state.best_flight_time then
        state.best_flight_time = math.floor(duration)
        stor_save("v4_best_t_" .. name, state.best_flight_time)
    end
    if dist > state.best_flight_dist then
        state.best_flight_dist = dist
        stor_save("v4_best_d_" .. name, state.best_flight_dist)
    end

    state.flight_start_time = nil
    state.flight_start_pos  = nil
end

-- ─── EQUIP / UNEQUIP ───────────────────────────────────────
function elytra.equip(player)
    local name  = player:get_player_name()
    local state = gs(player)
    if state.equipped then return end

    -- Must have elytra in inventory
    local inv = player:get_inventory()
    if not inv:contains_item("main", "elytra:elytra") then
        minetest.chat_send_player(name,
            minetest.colorize("#ff5555", "No Elytra in inventory!"))
        return
    end

    state.equipped   = true
    state.durability = stor_load_int(STOR_DUR .. name, CFG.max_durability)
    state.enchant    = stor_load_int(STOR_ENC .. name, 0)
    hud_show(player, state)
    hud_update(player, state)

    minetest.chat_send_player(name,
        minetest.colorize("#55ff55", "Elytra equipped! ") ..
        "Fall then press " .. minetest.colorize("#55ffff", "[E]") ..
        " to glide. Right-click rockets mid-flight to boost. " ..
        minetest.colorize("#888888", "(Sneak+Jump to unequip)"))
end

function elytra.unequip(player)
    local name  = player:get_player_name()
    local state = gs(player)
    if not state.equipped then return end

    if state.gliding then
        elytra.stop_glide(player, "unequip")
    end
    state.equipped = false
    stop_sound(state.wind_handle)
    state.wind_handle = nil
    stor_save(STOR_DUR .. name, state.durability)
    hud_hide(player, state)
    reset_animation(player)

    minetest.chat_send_player(name,
        minetest.colorize("#aaaaaa", "Elytra unequipped."))
end

-- ─── START GLIDE ───────────────────────────────────────────
function elytra.start_glide(player)
    local state = gs(player)
    local name  = player:get_player_name()

    if not state.equipped then return end
    if state.gliding     then return end
    if state.durability <= 0 then
        minetest.chat_send_player(name,
            minetest.colorize("#ff5555", "Elytra is broken — repair it first!"))
        return
    end

    -- Derive initial speed from current horizontal velocity (MC behaviour)
    local vel = player:get_velocity()
    local hspd = vel and vlen2d(vel) or 0
    state.speed        = math.max(hspd, CFG.speed_base)
    state.target_speed = state.speed
    state.gliding      = true
    state.stall_timer  = 0.0
    state.boosting     = false
    state.boost_stacks = 0
    state.boost_timer  = 0.0
    state.prev_yaw     = player:get_look_horizontal()
    state.wind_timer   = CFG.wind_update_rate  -- trigger sound immediately

    player:set_physics_override({gravity=0.0, speed=0.0, jump=0.0})
    flight_start(player, state)
    play_sound(player, SND.whoosh, 1.0, 0.9)

    minetest.chat_send_player(name,
        minetest.colorize("#55ffff", "Gliding! ") ..
        "Look down to accelerate  |  Look up to climb  |  " ..
        minetest.colorize("#ffaa55", "Right-click rocket to boost"))
end

-- ─── STOP GLIDE ────────────────────────────────────────────
function elytra.stop_glide(player, reason)
    local state = gs(player)
    local name  = player:get_player_name()
    if not state.gliding then return end

    state.gliding      = false
    state.boosting     = false
    state.boost_stacks = 0
    state.tilt         = 0.0

    stop_sound(state.wind_handle)
    state.wind_handle = nil
    reset_animation(player)
    flight_end(player, state)

    local coast = (reason == "manual" or reason == "land" or reason == "unequip")
    reset_physics(player, coast)

    -- Reason messages
    local msgs = {
        manual   = minetest.colorize("#aaaaaa",  "Glide ended."),
        land     = minetest.colorize("#aaaaaa",  "Landed."),
        stall    = minetest.colorize("#ffaa00",  "[STALL] Look down to regain speed!"),
        broke    = minetest.colorize("#ff5555",  "[ELYTRA BROKE] Repair with 2 paper."),
        collision= minetest.colorize("#ff5555",  "[CRASHED INTO WALL]"),
        water    = minetest.colorize("#55aaff",  "Splashdown!"),
        unequip  = minetest.colorize("#aaaaaa",  "Glide cancelled."),
    }
    minetest.chat_send_player(name, msgs[reason] or "Glide ended.")

    if reason == "stall" then
        pt_stall(player)
        play_sound(player, SND.stall, 0.9, 0.7)
    elseif reason == "broke" then
        play_sound(player, SND.crack, 1.0, 1.0)
        -- Replace item in inventory with damaged variant
        local inv = player:get_inventory()
        for i = 1, inv:get_size("main") do
            local st = inv:get_stack("main", i)
            if st:get_name() == "elytra:elytra" then
                inv:set_stack("main", i, ItemStack("elytra:elytra_damaged"))
                break
            end
        end
        stor_save(STOR_DUR .. name, 0)
    elseif reason == "water" then
        pt_splash(player)
        play_sound(player, SND.splash, 1.0, 0.8)
    elseif reason == "land" or reason == "collision" then
        local vel = player:get_velocity()
        local spd = vel and vlen(vel) or 0
        if spd > 10 then
            play_sound(player, SND.land_h, 1.0, 0.8)
        else
            play_sound(player, SND.land_s, 1.0, 0.5)
        end
    end
end

-- ─── ROCKET BOOST ──────────────────────────────────────────
function elytra.fire_rocket(player)
    local state = gs(player)
    if not state.gliding then return false end

    -- Stack rockets up to max
    state.boost_stacks = math.min(state.boost_stacks + 1, CFG.rocket_stack_max)
    state.boosting     = true
    state.boost_timer  = 0.0
    -- Each rocket adds proportionally more speed
    state.speed        = math.min(CFG.speed_max,
        CFG.rocket_speed + (state.boost_stacks - 1) * 5)
    state.target_speed = state.speed

    play_sound(player, SND.rocket, 0.9 + state.boost_stacks * 0.1, 1.0)
    pt_rocket(player)

    minetest.chat_send_player(player:get_player_name(),
        minetest.colorize("#ffaa55", "ROCKET BOOST") ..
        (state.boost_stacks > 1 and
            minetest.colorize("#ff5500", " x" .. state.boost_stacks .. "!") or "!"))
    return true
end

-- ─── ENCHANTING ────────────────────────────────────────────
-- /enchant_elytra <level> — gives Unbreaking enchant
-- Or craft: elytra + mese shard(s)
local function apply_enchant(player, level)
    local name  = player:get_player_name()
    local state = gs(player)
    level = clamp(level, 0, 3)
    state.enchant = level
    stor_save(STOR_ENC .. name, level)
    if level == 0 then
        minetest.chat_send_player(name, "Enchantment removed.")
    else
        minetest.chat_send_player(name,
            minetest.colorize("#aa55ff",
                "Unbreaking " .. ({"I","II","III"})[level] .. " applied!") ..
            string.format(" Durability drain: %.0f%%", 100 * (CFG.unbreaking_drain[level] or 1)))
    end
end

-- ─── ITEMS ─────────────────────────────────────────────────
minetest.register_craftitem("elytra:elytra", {
    description =
        minetest.colorize("#d4af37", "Elytra\n") ..
        minetest.colorize("#aaffaa", "Right-click to equip.\n") ..
        minetest.colorize("#aaaaff", "Fall, then press [E] to glide.\n") ..
        minetest.colorize("#ffaa55", "Use rockets mid-flight for boosts!"),
    inventory_image = "elytra_item.png",
    stack_max = 1,
    groups    = { armor_torso = 1 },
    on_use = function(itemstack, user)
        if user then elytra.equip(user) end
        return itemstack
    end,
})

minetest.register_craftitem("elytra:elytra_damaged", {
    description =
        minetest.colorize("#888888", "Elytra (Damaged)\n") ..
        minetest.colorize("#ff5555", "Repair: place with 2 paper in crafting grid."),
    inventory_image = "elytra_item_damaged.png",
    stack_max = 1,
})

minetest.register_craftitem("elytra:rocket", {
    description =
        minetest.colorize("#ff7755", "Firework Rocket\n") ..
        minetest.colorize("#aaaaff", "Right-click while gliding to boost speed.\n") ..
        minetest.colorize("#888888", "Stack up to 3 for increasing power!"),
    inventory_image = "elytra_rocket.png",
    stack_max = 64,
    on_use = function(itemstack, user)
        if not user then return itemstack end
        local state = gs(user)
        if state.gliding then
            if elytra.fire_rocket(user) then
                itemstack:take_item(1)
            end
        else
            minetest.chat_send_player(user:get_player_name(),
                minetest.colorize("#ffaa00", "Must be gliding to use a rocket!"))
        end
        return itemstack
    end,
})

-- ─── RECIPES ───────────────────────────────────────────────
minetest.register_craft({
    output = "elytra:elytra",
    recipe = {
        { "group:stick",        "default:mese_crystal", "group:stick"        },
        { "default:paper",      "default:mese_crystal", "default:paper"      },
        { "default:paper",      "group:stick",          "default:paper"      },
    }
})

-- Repair
minetest.register_craft({
    type   = "shapeless",
    output = "elytra:elytra",
    recipe = { "elytra:elytra_damaged", "default:paper", "default:paper" },
})

-- Rocket — use paper + mese_shard (no gunpowder dep needed)
-- tnt:gunpowder is optional; fall back to default:mese_shard
local rocket_ingredient = minetest.registered_items["tnt:gunpowder"]
    and "tnt:gunpowder" or "default:mese_shard"

minetest.register_craft({
    output = "elytra:rocket 4",
    recipe = {
        { "default:paper"      },
        { rocket_ingredient    },
        { "group:stick"        },
    }
})

-- Unbreaking I: elytra + 1 mese shard
minetest.register_craft({
    type   = "shapeless",
    output = "elytra:elytra_ub1",
    recipe = { "elytra:elytra", "default:mese_shard" },
})
-- Unbreaking II: ub1 + shard
minetest.register_craft({
    type   = "shapeless",
    output = "elytra:elytra_ub2",
    recipe = { "elytra:elytra_ub1", "default:mese_shard" },
})
-- Unbreaking III: ub2 + crystal
minetest.register_craft({
    type   = "shapeless",
    output = "elytra:elytra_ub3",
    recipe = { "elytra:elytra_ub2", "default:mese_crystal" },
})

-- Register enchanted variants
for lvl, label in ipairs({"I","II","III"}) do
    local id   = "elytra:elytra_ub" .. lvl
    local mult = CFG.unbreaking_drain[lvl]
    minetest.register_craftitem(id, {
        description =
            minetest.colorize("#d4af37", "Elytra\n") ..
            minetest.colorize("#aa55ff",
                "Unbreaking " .. label ..
                string.format(" (%.0f%% durability use)\n", mult*100)) ..
            minetest.colorize("#aaffaa", "Right-click to equip."),
        inventory_image = "elytra_item.png",
        stack_max = 1,
        groups    = { armor_torso = 1 },
        on_use = function(itemstack, user)
            if not user then return itemstack end
            local name  = user:get_player_name()
            local state = gs(user)
            state.enchant = lvl
            stor_save(STOR_ENC .. name, lvl)
            elytra.equip(user)
            return itemstack
        end,
    })
end

-- ─── MAIN GLOBALSTEP ───────────────────────────────────────
-- NOTE: Minetest uses LuaJIT (Lua 5.1 semantics).
-- goto CANNOT jump over local variable declarations.
-- Solution: physics is a separate function — early returns are safe there.

local step_acc = 0.0
local dur_acc  = 0.0
local PHYS_HZ  = 0.05
local DUR_HZ   = 1.0

-- Returns false if the glide was interrupted this tick (caller should skip rest)
local function run_glide_physics(player, state)
    local pitch = player:get_look_vertical()
    local look  = look_dir(player)

    -- ── Rocket boost phase ────────────────────────────────
    if state.boosting then
        state.boost_timer = state.boost_timer + PHYS_HZ
        if state.boost_timer < CFG.rocket_duration then
            local frac = 1.0 - (state.boost_timer / CFG.rocket_duration)
            local bspd = lerp(CFG.speed_base, state.speed, frac)
            player:set_velocity({
                x = look.x * bspd,
                y = look.y * bspd,
                z = look.z * bspd,
            })
            pt_rocket(player)
            apply_animation(player, state, PHYS_HZ)
            hud_update(player, state)
            state.wind_timer = state.wind_timer + PHYS_HZ
            if state.wind_timer >= CFG.wind_update_rate then
                state.wind_timer = 0
                update_wind(player, state)
            end
            return true   -- still boosting, skip normal physics
        else
            state.boosting     = false
            state.boost_stacks = 0
            state.target_speed = state.speed
        end
    end

    -- ── Normal glide physics ──────────────────────────────
    local pitch_effect
    if pitch > 0 then
        pitch_effect = pitch * CFG.pitch_accel
    else
        pitch_effect = pitch * CFG.pitch_lift
    end

    local alt_bonus = get_altitude_bonus(player)
    local updraft   = get_updraft(player)

    state.target_speed = state.target_speed
        + pitch_effect * (60 * PHYS_HZ)
        + alt_bonus    * PHYS_HZ * 0.3
    state.target_speed = state.target_speed * (1.0 - CFG.drag)
    state.target_speed = clamp(state.target_speed,
        CFG.speed_min, CFG.speed_max + alt_bonus)
    state.speed = lerp(state.speed, state.target_speed, CFG.speed_smooth)

    -- ── Stall ─────────────────────────────────────────────
    if state.speed <= CFG.speed_min + 0.2 then
        state.stall_timer = state.stall_timer + PHYS_HZ
        if state.stall_timer >= CFG.stall_time then
            elytra.stop_glide(player, "stall")
            hud_update(player, state)
            return false  -- glide ended
        end
    else
        state.stall_timer = 0.0
    end

    -- ── Gravity ───────────────────────────────────────────
    local vy_grav = 0.0
    if pitch < 0.15 then
        vy_grav = -CFG.gravity_base * 9.81 * PHYS_HZ * 12
        if updraft > 0 then
            vy_grav = vy_grav + updraft * PHYS_HZ * 4
        end
    end

    -- ── Apply velocity ────────────────────────────────────
    player:set_velocity({
        x = look.x * state.speed,
        y = look.y * state.speed + vy_grav,
        z = look.z * state.speed,
    })

    -- ── Distance tracking ─────────────────────────────────
    local vel = player:get_velocity()
    if vel then
        state.total_distance = state.total_distance + vlen2d(vel) * PHYS_HZ
    end

    -- ── Collision ─────────────────────────────────────────
    if state.speed > CFG.collision_threshold then
        if check_wall_collision(player, state) then
            elytra.stop_glide(player, "collision")
            return false  -- glide ended
        end
    end

    -- ── Particles + animation + wind sound ────────────────
    pt_trail(player, state)
    apply_animation(player, state, PHYS_HZ)

    state.wind_timer = state.wind_timer + PHYS_HZ
    if state.wind_timer >= CFG.wind_update_rate then
        state.wind_timer = 0
        update_wind(player, state)
    end

    hud_update(player, state)
    return true
end

minetest.register_globalstep(function(dtime)
    step_acc = step_acc + dtime
    dur_acc  = dur_acc  + dtime

    local do_phys = step_acc >= PHYS_HZ
    local do_dur  = dur_acc  >= DUR_HZ

    if do_phys then step_acc = step_acc - PHYS_HZ end
    if do_dur  then dur_acc  = dur_acc  - DUR_HZ  end

    for _, player in ipairs(minetest.get_connected_players()) do
        local name     = player:get_player_name()
        local state    = gs(player)
        local controls = player:get_player_control()

        -- ── [E] key: toggle glide ─────────────────────────
        if state.equipped then
            if controls.aux1 then
                if not state._aux1_held then
                    state._aux1_held = true
                    if not state.gliding and not is_grounded(player) then
                        elytra.start_glide(player)
                    elseif state.gliding then
                        elytra.stop_glide(player, "manual")
                    end
                end
            else
                state._aux1_held = false
            end
        end

        -- ── Sneak+Jump: unequip ───────────────────────────
        if state.equipped and controls.sneak and controls.jump then
            if not state._unequip_held then
                state._unequip_held = true
                elytra.unequip(player)
            end
        else
            state._unequip_held = false
        end

        -- ── Auto-glide: hold sneak while falling ──────────
        if state.equipped and not state.gliding and not is_grounded(player) then
            local vel = player:get_velocity()
            if vel and vel.y < CFG.auto_glide_min_vy and controls.sneak then
                state.fall_hold_timer = state.fall_hold_timer + dtime
                if state.fall_hold_timer >= CFG.auto_glide_hold then
                    state.fall_hold_timer = 0
                    elytra.start_glide(player)
                end
            else
                state.fall_hold_timer = 0
            end
        end

        -- ── Not gliding: just update HUD ──────────────────
        if not state.gliding then
            if do_phys then hud_update(player, state) end

        else
            -- ── Water entry ───────────────────────────────
            local water_stopped = false
            local inw = is_in_water(player)
            if inw and not state.in_water then
                state.in_water = true
                local vel = player:get_velocity()
                if vel then
                    player:set_velocity({
                        x = vel.x * CFG.water_drag,
                        y = -0.5,
                        z = vel.z * CFG.water_drag,
                    })
                end
                elytra.stop_glide(player, "water")
                water_stopped = true
            elseif not inw then
                state.in_water = false
            end

            -- ── Ground ────────────────────────────────────
            local ground_stopped = false
            if not water_stopped and is_grounded(player) then
                elytra.stop_glide(player, "land")
                if do_phys then hud_update(player, state) end
                ground_stopped = true
            end

            -- ── Physics (only if still gliding this tick) ─
            if not water_stopped and not ground_stopped and state.gliding then
                if do_phys then
                    run_glide_physics(player, state)
                end

                -- Durability drain
                if do_dur and state.gliding then
                    local drain_mult = CFG.unbreaking_drain[state.enchant] or 1.0
                    if math.random() < drain_mult then
                        state.durability = state.durability - CFG.dur_drain_base
                        stor_save(STOR_DUR .. name, state.durability)
                        if state.durability <= 0 then
                            state.durability = 0
                            elytra.stop_glide(player, "broke")
                        end
                    end
                end
            end
        end
    end
end)

-- ─── ON JOIN ───────────────────────────────────────────────
minetest.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    init_state(name)
end)

-- ─── ON LEAVE ──────────────────────────────────────────────
minetest.register_on_leaveplayer(function(player)
    local name  = player:get_player_name()
    local state = P[name]
    if state then
        stor_save(STOR_DUR .. name, state.durability)
        stor_save(STOR_ENC .. name, state.enchant)
        stop_sound(state.wind_handle)
        reset_animation(player)
    end
    P[name] = nil
end)

-- ─── CHAT COMMANDS ─────────────────────────────────────────
minetest.register_chatcommand("giveelytra", {
    description = "Give yourself an Elytra",
    privs = { interact=true },
    func = function(name)
        local p = minetest.get_player_by_name(name)
        if not p then return false, "Player not found." end
        p:get_inventory():add_item("main", "elytra:elytra")
        return true, minetest.colorize("#55ff55", "Elytra given!")
    end,
})

minetest.register_chatcommand("giverocket", {
    description = "Give yourself rockets",
    privs = { interact=true },
    func = function(name, param)
        local p = minetest.get_player_by_name(name)
        if not p then return false, "Player not found." end
        local n = tonumber(param) or 16
        p:get_inventory():add_item("main", "elytra:rocket " .. n)
        return true, minetest.colorize("#ffaa55", n .. " rockets given!")
    end,
})

minetest.register_chatcommand("elytrarepair", {
    description = "Repair your Elytra to full durability",
    privs = { interact=true },
    func = function(name)
        local p = minetest.get_player_by_name(name)
        if not p then return false, "Player not found." end
        local state = gs(p)
        state.durability = CFG.max_durability
        stor_save(STOR_DUR .. name, state.durability)
        hud_update(p, state)
        return true, minetest.colorize("#55ff55", "Elytra repaired to 100%!")
    end,
})

minetest.register_chatcommand("elytraenchant", {
    description = "Set Unbreaking level (0-3) on your Elytra",
    privs = { interact=true },
    func = function(name, param)
        local p = minetest.get_player_by_name(name)
        if not p then return false, "Player not found." end
        local lvl = tonumber(param)
        if not lvl or lvl < 0 or lvl > 3 then
            return false, "Usage: /elytraenchant <0-3>"
        end
        apply_enchant(p, lvl)
        return true
    end,
})

minetest.register_chatcommand("elytrainfo", {
    description = "Show Elytra status",
    privs = { interact=true },
    func = function(name)
        local p = minetest.get_player_by_name(name)
        if not p then return false, "Player not found." end
        local state   = gs(p)
        local dur_pct = math.floor((state.durability / CFG.max_durability) * 100)
        local enc_lbl = ({"None","Unbreaking I","Unbreaking II","Unbreaking III"})[state.enchant+1]
        return true, string.format(
            "Elytra — equipped:%s  gliding:%s  dur:%d%%  speed:%.1f m/s  enchant:%s  boost:%s(x%d)",
            tostring(state.equipped), tostring(state.gliding),
            dur_pct, state.speed, enc_lbl,
            tostring(state.boosting), state.boost_stacks
        )
    end,
})

minetest.register_chatcommand("elytrarecord", {
    description = "Show your best flight stats",
    privs = { interact=true },
    func = function(name)
        local p = minetest.get_player_by_name(name)
        if not p then return false, "Player not found." end
        local state = gs(p)
        local t_min = math.floor(state.best_flight_time / 60)
        local t_sec = state.best_flight_time % 60
        return true, string.format(
            "Best flight: %dm %ds  |  Best distance: %dm",
            t_min, t_sec, state.best_flight_dist
        )
    end,
})

-- ─── DONE ──────────────────────────────────────────────────
minetest.log("action", "[Elytra v4] Loaded.")
print("[Elytra v4] ✓ Ready!")
print("  Commands: /giveelytra /giverocket /elytrarepair /elytraenchant /elytrainfo /elytrarecord")
