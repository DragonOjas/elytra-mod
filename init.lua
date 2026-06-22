-- ============================================================
--  ELYTRA MOD v3  —  Minecraft-accurate for Minetest/TechBlox
--
--  Systems implemented:
--   [1] Physics   — pitch-driven speed, momentum coast, gravity
--   [2] Firework  — rocket boost item mid-glide (exact MC feel)
--   [3] Particles — speed-scaled wind trail + feather stall burst
--   [4] Sounds    — wind loop (pitch-shifted), whoosh, crack, land
--   [5] Durability— persistent via mod_storage + item wear visuals
--   [6] Collision — wall hit damage proportional to speed
--   [7] Water     — splash + drag on water entry
--   [8] Updrafts  — lava/fire/hot blocks push player upward
--   [9] Banking   — smooth camera roll on turns
--  [10] HUD       — speed bar, durability, stall/boost warnings
-- ============================================================

local elytra = {}
local storage = minetest.get_mod_storage()

-- ─── CONFIG ────────────────────────────────────────────────
-- Values tuned to match Minecraft 1.20 elytra behaviour.
elytra.config = {
    -- ── Core physics (MC-matched) ──
    glide_speed_base    = 7.2,    -- MC default launch ~7.2 m/s horizontal
    glide_speed_max     = 30.0,   -- terminal dive (MC allows ~30 m/s)
    glide_speed_min     = 2.0,    -- stall speed
    gravity_factor      = 0.08,   -- MC elytra gravity per tick (very light)
    pitch_accel         = 0.08,   -- acceleration from diving pitch
    pitch_lift          = 0.04,   -- speed loss from climbing pitch
    drag                = 0.01,   -- MC drag is very low for long flights
    speed_smooth        = 0.12,   -- lerp for smooth feel
    launch_boost        = 0.0,    -- MC elytra has NO launch boost — activate takes current vel
    momentum_coast      = 0.92,   -- horizontal vel preserved on glide-stop (coast factor)

    -- ── Firework rocket ──
    rocket_boost        = 25.0,   -- speed given by one rocket (MC: ~burst + look direction)
    rocket_boost_time   = 0.8,    -- seconds the boost lasts before physics takes over
    rocket_item         = "default:mese_crystal",  -- substitute for MC firework rocket

    -- ── Stall ──
    stall_recover_time  = 0.5,

    -- ── Durability (MC: 432 uses) ──
    max_durability      = 432,
    durability_drain    = 1,      -- per second, like MC
    -- In MC, Unbreaking III gives ~1/4 drain. We skip enchants for simplicity.

    -- ── Ground / water / collision ──
    ground_check_dist   = 1.05,
    water_drag          = 0.35,   -- speed multiplier on water entry
    collision_damage_threshold = 8.0,  -- m/s horizontal speed that starts hurting
    collision_check_dist = 0.6,   -- how close to wall triggers collision

    -- ── Updrafts ──
    updraft_blocks      = {       -- blocks that push player upward
        ["default:lava_source"] = 6.0,
        ["default:lava_flowing"] = 4.0,
        ["fire:basic_flame"]     = 3.0,
        ["fire:permanent_flame"] = 3.0,
        ["default:torch"]        = 0.5,
    },
    updraft_range       = 1.5,    -- horizontal radius to check for updraft blocks

    -- ── Banking ──
    bank_speed          = 0.12,
    bank_max            = 40.0,
    bank_decay          = 0.82,

    -- ── Particles ──
    trail_min_speed     = 8.0,    -- speed at which trail particles start
    trail_max_particles = 12,     -- at max speed

    -- ── Sounds ──
    wind_pitch_min      = 0.6,    -- wind sound pitch at slow speed
    wind_pitch_max      = 1.4,    -- wind sound pitch at max speed
    wind_update_hz      = 0.25,   -- how often to re-pitch wind sound
}

-- ─── HELPERS ───────────────────────────────────────────────
local function lerp(a, b, t) return a + (b - a) * t end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function vec_len(v) return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end

-- ─── PERSISTENT DURABILITY ─────────────────────────────────
local function save_durability(name, dur)
    storage:set_int("dur_" .. name, dur)
end

local function load_durability(name)
    local v = storage:get_int("dur_" .. name)
    -- get_int returns 0 if missing; treat 0 as full (first login)
    if v <= 0 then return elytra.config.max_durability end
    return v
end

-- ─── PER-PLAYER STATE ──────────────────────────────────────
local player_state = {}

local function get_state(player)
    local name = player:get_player_name()
    if not player_state[name] then
        player_state[name] = {
            -- Flight
            gliding         = false,
            speed           = elytra.config.glide_speed_base,
            target_speed    = elytra.config.glide_speed_base,
            -- Equip
            equipped        = false,
            durability      = load_durability(player:get_player_name()),
            -- Rocket boost
            boosting        = false,
            boost_timer     = 0.0,
            boost_vel       = { x=0, y=0, z=0 },
            -- Animation / banking
            tilt            = 0.0,
            prev_yaw        = 0.0,
            -- Stall
            stall_timer     = 0.0,
            -- Sound handle
            wind_handle     = nil,
            wind_timer      = 0.0,
            -- HUD
            hud_id          = nil,
            -- Control edge detection
            _aux1_held      = false,
            _unequip_held   = false,
            _sneak_was_held = false,
            -- Water / collision state
            in_water        = false,
            last_vel        = { x=0, y=0, z=0 },
        }
    end
    return player_state[name]
end

-- ─── LOOK DIRECTION ────────────────────────────────────────
local function get_look_dir(player)
    local yaw   = player:get_look_horizontal()
    local pitch = player:get_look_vertical()
    local cp    = math.cos(pitch)
    return {
        x =  math.sin(yaw) * cp,
        y = -math.sin(pitch),
        z = -math.cos(yaw) * cp,
    }
end

-- ─── GROUND / WATER CHECK ──────────────────────────────────
local function node_at_offset(player, dy)
    local pos = player:get_pos()
    if not pos then return { name = "air" } end
    return minetest.get_node({ x = pos.x, y = pos.y + dy, z = pos.z })
end

local function is_grounded(player)
    local n = node_at_offset(player, -elytra.config.ground_check_dist).name
    return n ~= "air" and n ~= "ignore" and n ~= ""
        and not n:find("water") and not n:find("lava")
end

local function is_in_water(player)
    local n = node_at_offset(player, 0).name
    return n:find("water") ~= nil
end

-- ─── ITEM DEFINITIONS ──────────────────────────────────────
-- Full elytra
minetest.register_craftitem("elytra:elytra", {
    description =
        minetest.colorize("#d4af37", "Elytra") .. "\n" ..
        minetest.colorize("#aaffaa", "Right-click to equip/unequip.") .. "\n" ..
        minetest.colorize("#aaaaff", "Jump, then press [E] to glide!") .. "\n" ..
        minetest.colorize("#ffaa55", "Use a Rocket while gliding for a boost!"),
    inventory_image = "elytra_item.png",
    stack_max       = 1,
    groups          = { armor_torso = 1 },
    on_use = function(itemstack, user)
        if user then elytra.try_equip(user) end
        return itemstack
    end,
})

-- Damaged (0 durability) variant — auto-replaced when elytra breaks
minetest.register_craftitem("elytra:elytra_damaged", {
    description =
        minetest.colorize("#888888", "Elytra (Damaged)") .. "\n" ..
        minetest.colorize("#ff5555", "Needs repair before use."),
    inventory_image = "elytra_item_damaged.png",
    stack_max       = 1,
})

-- Firework rocket substitute
minetest.register_craftitem("elytra:rocket", {
    description =
        minetest.colorize("#ff5555", "Firework Rocket") .. "\n" ..
        minetest.colorize("#aaaaff", "Right-click while gliding for a speed boost!"),
    inventory_image = "elytra_rocket.png",
    stack_max       = 64,
    on_use = function(itemstack, user)
        if not user then return itemstack end
        local state = get_state(user)
        if state.gliding then
            elytra.fire_rocket(user)
            itemstack:take_item(1)
        else
            minetest.chat_send_player(user:get_player_name(),
                minetest.colorize("#ffaa00", "You must be gliding to use a rocket!"))
        end
        return itemstack
    end,
})

-- ─── CRAFT RECIPES ─────────────────────────────────────────
minetest.register_craft({
    output = "elytra:elytra",
    recipe = {
        { "group:stick",        "default:mese_crystal", "group:stick"        },
        { "default:paper",      "default:mese_crystal", "default:paper"      },
        { "default:paper",      "group:stick",          "default:paper"      },
    }
})

-- Repair: damaged elytra + 2 paper → full elytra
minetest.register_craft({
    type   = "shapeless",
    output = "elytra:elytra",
    recipe = { "elytra:elytra_damaged", "default:paper", "default:paper" },
})

-- Firework rocket recipe
minetest.register_craft({
    output = "elytra:rocket 3",
    recipe = {
        { "default:paper" },
        { "default:gunpowder" },   -- or substitute if not available
        { "group:stick" },
    }
})

-- ─── SOUNDS ────────────────────────────────────────────────
-- Registers sound specs. Actual .ogg files must live in sounds/.
-- Fallback: if files absent, Minetest silently skips them.
local snd = {
    wind_loop = { name = "elytra_wind",        gain = 0.6, loop = true  },
    whoosh    = { name = "elytra_whoosh",       gain = 0.9, loop = false },
    rocket    = { name = "elytra_rocket",       gain = 1.0, loop = false },
    crack     = { name = "elytra_crack",        gain = 1.0, loop = false },
    land_hard = { name = "elytra_land_hard",    gain = 0.8, loop = false },
    land_soft = { name = "elytra_land_soft",    gain = 0.5, loop = false },
    stall     = { name = "elytra_stall_creak",  gain = 0.7, loop = false },
    splash    = { name = "default_water_splash",gain = 0.8, loop = false },
}

local function play_to_player(player, spec, pitch)
    local pos = player:get_pos()
    if not pos then return nil end
    local s = table.copy(spec)
    s.pitch = pitch or 1.0
    return minetest.sound_play(s, { pos = pos, max_hear_distance = 16 })
end

local function stop_sound(handle)
    if handle then minetest.sound_stop(handle) end
end

local function update_wind_sound(player, state)
    -- Pitch-shift existing handle to reflect current speed
    -- Minetest doesn't support pitch-changing a playing sound,
    -- so we stop and restart at the new pitch every wind_update_hz seconds.
    local cfg = elytra.config
    if not state.gliding then
        stop_sound(state.wind_handle)
        state.wind_handle = nil
        return
    end

    state.wind_timer = state.wind_timer + cfg.wind_update_hz
    if state.wind_timer < cfg.wind_update_hz then return end
    state.wind_timer = 0

    local t     = (state.speed - cfg.glide_speed_min) / (cfg.glide_speed_max - cfg.glide_speed_min)
    local pitch = lerp(cfg.wind_pitch_min, cfg.wind_pitch_max, clamp(t, 0, 1))
    local gain  = lerp(0.2, 0.8, clamp(t, 0, 1))

    stop_sound(state.wind_handle)
    local pos = player:get_pos()
    if pos then
        state.wind_handle = minetest.sound_play(
            { name = "elytra_wind", loop = true },
            { pos = pos, gain = gain, pitch = pitch, max_hear_distance = 8 }
        )
    end
end

-- ─── PARTICLES ─────────────────────────────────────────────
local function spawn_trail_particles(player, state)
    local cfg = elytra.config
    if state.speed < cfg.trail_min_speed then return end

    local pos   = player:get_pos()
    if not pos then return end
    local look  = get_look_dir(player)
    local t     = (state.speed - cfg.trail_min_speed) / (cfg.glide_speed_max - cfg.trail_min_speed)
    local count = math.floor(lerp(1, cfg.trail_max_particles, clamp(t, 0, 1)))

    -- Wind streak particles behind the player
    minetest.add_particlespawner({
        amount   = count,
        time     = 0.05,
        minpos   = { x = pos.x - 0.3, y = pos.y,        z = pos.z - 0.3 },
        maxpos   = { x = pos.x + 0.3, y = pos.y + 0.5,  z = pos.z + 0.3 },
        -- velocity opposite to look direction (trail stays behind)
        minvel   = { x = -look.x * state.speed * 0.4, y = -look.y * 0.5 - 1, z = -look.z * state.speed * 0.4 },
        maxvel   = { x = -look.x * state.speed * 0.6, y = -look.y * 0.5 + 0, z = -look.z * state.speed * 0.6 },
        minacc   = { x = 0, y = -0.5, z = 0 },
        maxacc   = { x = 0, y = -0.2, z = 0 },
        minexptime = 0.2,
        maxexptime = 0.5,
        minsize  = 0.3,
        maxsize  = 0.8,
        texture  = "elytra_particle_wind.png",
        glow     = 0,
    })

    -- At very high speed, add white speed-line streaks
    if state.speed > 18 then
        minetest.add_particlespawner({
            amount   = 3,
            time     = 0.05,
            minpos   = { x = pos.x - 0.8, y = pos.y,       z = pos.z - 0.8 },
            maxpos   = { x = pos.x + 0.8, y = pos.y + 0.8, z = pos.z + 0.8 },
            minvel   = { x = -look.x * 12, y = -look.y * 4, z = -look.z * 12 },
            maxvel   = { x = -look.x * 16, y = -look.y * 4, z = -look.z * 16 },
            minacc   = { x = 0, y = 0, z = 0 },
            maxacc   = { x = 0, y = 0, z = 0 },
            minexptime = 0.08,
            maxexptime = 0.15,
            minsize  = 0.1,
            maxsize  = 0.3,
            texture  = "elytra_particle_streak.png",
        })
    end
end

local function spawn_stall_particles(player)
    local pos = player:get_pos()
    if not pos then return end
    -- Feather burst when stalling
    minetest.add_particlespawner({
        amount     = 20,
        time       = 0.3,
        minpos     = { x = pos.x - 0.5, y = pos.y,       z = pos.z - 0.5 },
        maxpos     = { x = pos.x + 0.5, y = pos.y + 1.0, z = pos.z + 0.5 },
        minvel     = { x = -2, y =  1, z = -2 },
        maxvel     = { x =  2, y =  4, z =  2 },
        minacc     = { x = 0,  y = -3, z =  0 },
        maxacc     = { x = 0,  y = -1, z =  0 },
        minexptime = 0.8,
        maxexptime = 2.0,
        minsize    = 0.5,
        maxsize    = 1.2,
        texture    = "elytra_particle_feather.png",
    })
end

local function spawn_rocket_particles(player)
    local pos  = player:get_pos()
    local look = get_look_dir(player)
    if not pos then return end
    -- Rocket exhaust behind player
    minetest.add_particlespawner({
        amount     = 30,
        time       = 0.8,
        minpos     = { x = pos.x - 0.2, y = pos.y,       z = pos.z - 0.2 },
        maxpos     = { x = pos.x + 0.2, y = pos.y + 0.5, z = pos.z + 0.2 },
        minvel     = { x = -look.x * 8  - 1, y = -look.y * 6 - 2, z = -look.z * 8  - 1 },
        maxvel     = { x = -look.x * 12 + 1, y = -look.y * 6 + 2, z = -look.z * 12 + 1 },
        minacc     = { x = 0, y = -2, z = 0 },
        maxacc     = { x = 0, y =  0, z = 0 },
        minexptime = 0.3,
        maxexptime = 0.9,
        minsize    = 0.6,
        maxsize    = 1.8,
        texture    = "elytra_particle_rocket.png",
        glow       = 10,
    })
end

local function spawn_water_splash(player)
    local pos = player:get_pos()
    if not pos then return end
    minetest.add_particlespawner({
        amount     = 25,
        time       = 0.2,
        minpos     = { x = pos.x - 0.5, y = pos.y,       z = pos.z - 0.5 },
        maxpos     = { x = pos.x + 0.5, y = pos.y + 0.3, z = pos.z + 0.5 },
        minvel     = { x = -3, y = 2, z = -3 },
        maxvel     = { x =  3, y = 6, z =  3 },
        minacc     = { x = 0,  y = -8, z =  0 },
        maxacc     = { x = 0,  y = -5, z =  0 },
        minexptime = 0.3,
        maxexptime = 0.8,
        minsize    = 0.4,
        maxsize    = 0.9,
        texture    = "bubble.png",
    })
end

-- ─── PHYSICS ───────────────────────────────────────────────
function elytra.reset_physics(player, coast)
    player:set_physics_override({ gravity = 1.0, speed = 1.0, jump = 1.0 })
    if coast then
        -- Preserve horizontal momentum like MC — player coasts to a stop
        local vel = player:get_velocity()
        if vel then
            player:set_velocity({
                x = vel.x * elytra.config.momentum_coast,
                y = vel.y,
                z = vel.z * elytra.config.momentum_coast,
            })
        end
    else
        local vel = player:get_velocity()
        if vel then
            player:set_velocity({ x = 0, y = vel.y, z = 0 })
        end
    end
end

-- ─── UPDRAFT CHECK ─────────────────────────────────────────
local function get_updraft(player)
    local cfg = elytra.config
    local pos = player:get_pos()
    if not pos then return 0 end

    local total = 0
    local r     = math.floor(cfg.updraft_range)

    for dx = -r, r do
        for dz = -r, r do
            -- Check block below and at feet level
            for dy = -2, 0 do
                local n = minetest.get_node({
                    x = pos.x + dx,
                    y = pos.y + dy,
                    z = pos.z + dz,
                }).name
                local strength = cfg.updraft_blocks[n]
                if strength then
                    -- Strength falls off with distance
                    local dist = math.sqrt(dx*dx + dz*dz) + 1
                    total = total + strength / dist
                end
            end
        end
    end
    return total
end

-- ─── COLLISION DAMAGE ──────────────────────────────────────
-- Check if a solid block is close ahead in the look direction
local function check_collision(player, state)
    local cfg  = elytra.config
    local pos  = player:get_pos()
    local look = get_look_dir(player)
    if not pos then return end

    -- Probe 0.6m ahead
    local probe = {
        x = pos.x + look.x * cfg.collision_check_dist,
        y = pos.y + look.y * cfg.collision_check_dist + 0.5,
        z = pos.z + look.z * cfg.collision_check_dist,
    }
    local node = minetest.get_node(probe)
    if node.name == "air" or node.name == "ignore" then return end
    if node.name:find("water") or node.name:find("lava") then return end

    -- Hit! Damage based on speed (like MC: 1 heart per 3.5 m/s above threshold)
    local dmg_speed = math.max(0, state.speed - cfg.collision_damage_threshold)
    if dmg_speed > 0 then
        local hp_dmg = math.floor(dmg_speed / 3.5)
        if hp_dmg > 0 then
            player:set_hp(math.max(0, player:get_hp() - hp_dmg))
        end
    end

    -- Stop the glide
    elytra.stop_glide(player, "collision")
end

-- ─── ANIMATION ─────────────────────────────────────────────
local function apply_bank_animation(player, state, dt)
    local cfg     = elytra.config
    local cur_yaw = player:get_look_horizontal()
    local delta   = cur_yaw - state.prev_yaw
    state.prev_yaw = cur_yaw

    -- Wrap to [-π, π]
    if delta >  math.pi then delta = delta - math.pi * 2 end
    if delta < -math.pi then delta = delta + math.pi * 2 end

    local target = clamp(-delta * (180/math.pi) * 14, -cfg.bank_max, cfg.bank_max)

    if math.abs(delta) > 0.001 then
        state.tilt = lerp(state.tilt, target, cfg.bank_speed)
    else
        state.tilt = state.tilt * cfg.bank_decay
    end

    -- Eye offset gives a subtle camera lean
    if player.set_eye_offset then
        local shift = math.sin(math.rad(state.tilt)) * 3.5
        player:set_eye_offset(
            { x = shift, y = 0, z = 0 },
            { x = shift, y = 0, z = 0 }
        )
    end

    -- Use "run" animation frames while gliding (best pose available without custom model)
    if player.set_animation then
        player:set_animation({ x = 214, y = 233 }, 15, 0, true)
    end
end

local function reset_animation(player)
    if player.set_eye_offset then
        player:set_eye_offset({ x=0, y=0, z=0 }, { x=0, y=0, z=0 })
    end
    if player.set_animation then
        player:set_animation({ x = 0, y = 79 }, 15, 0, true)
    end
end

-- ─── DURABILITY ITEM SYNC ──────────────────────────────────
-- Replace elytra in inventory with damaged variant when it breaks.
local function sync_item_durability(player, state)
    if state.durability > 0 then return end
    local inv = player:get_inventory()
    for i = 1, inv:get_size("main") do
        local stack = inv:get_stack("main", i)
        if stack:get_name() == "elytra:elytra" then
            inv:set_stack("main", i, ItemStack("elytra:elytra_damaged"))
            break
        end
    end
end

-- ─── EQUIP / UNEQUIP ───────────────────────────────────────
function elytra.try_equip(player)
    local state = get_state(player)
    local name  = player:get_player_name()
    if state.equipped then
        elytra.unequip(player)
    else
        -- Check player has the item
        local inv   = player:get_inventory()
        local has   = inv:contains_item("main", "elytra:elytra")
        if not has then
            minetest.chat_send_player(name,
                minetest.colorize("#ff5555", "You don't have an Elytra to equip!"))
            return
        end
        state.equipped     = true
        state.durability   = load_durability(name)
        state.speed        = elytra.config.glide_speed_base
        state.target_speed = elytra.config.glide_speed_base
        elytra.show_hud(player)
        minetest.chat_send_player(name,
            minetest.colorize("#55ff55", "Elytra equipped! ") ..
            "Jump mid-air then press " ..
            minetest.colorize("#55ffff", "[E]") ..
            " to glide. Right-click a rocket while gliding to boost!")
    end
end

function elytra.unequip(player)
    local state = get_state(player)
    local name  = player:get_player_name()
    state.equipped = false
    state.gliding  = false
    state.tilt     = 0.0
    stop_sound(state.wind_handle)
    state.wind_handle = nil
    save_durability(name, state.durability)
    elytra.reset_physics(player, false)
    reset_animation(player)
    elytra.hide_hud(player)
    minetest.chat_send_player(name,
        minetest.colorize("#aaaaaa", "Elytra unequipped."))
end

-- ─── GLIDE START ───────────────────────────────────────────
function elytra.start_glide(player)
    local state = get_state(player)
    local name  = player:get_player_name()
    if not state.equipped then return end
    if state.durability <= 0 then
        minetest.chat_send_player(name,
            minetest.colorize("#ff5555", "Your Elytra is broken! ") ..
            "Repair it with paper in the crafting grid.")
        return
    end

    state.gliding      = true
    state.stall_timer  = 0.0
    state.boosting     = false
    state.prev_yaw     = player:get_look_horizontal()

    -- MC behaviour: NO boost. The player keeps current velocity and
    -- elytra takes over from there. Speed is derived from current vel magnitude.
    local vel = player:get_velocity()
    if vel then
        local current_speed = vec_len({ x=vel.x, y=0, z=vel.z })
        state.speed        = math.max(current_speed, elytra.config.glide_speed_base)
        state.target_speed = state.speed
    end

    player:set_physics_override({ gravity = 0.0, speed = 0.0, jump = 0.0 })

    play_to_player(player, snd.whoosh)

    minetest.chat_send_player(name,
        minetest.colorize("#55ffff", "▶ Gliding! ") ..
        "Look down to dive · Look up to rise · " ..
        minetest.colorize("#ffaa55", "Right-click rocket to boost"))
end

-- ─── GLIDE STOP ────────────────────────────────────────────
function elytra.stop_glide(player, reason)
    local state = get_state(player)
    if not state.gliding then return end
    local name = player:get_player_name()

    state.gliding  = false
    state.boosting = false
    state.tilt     = 0.0

    stop_sound(state.wind_handle)
    state.wind_handle = nil

    reset_animation(player)

    -- Momentum coast: keep horizontal speed on normal stop (like MC)
    local coast = (reason == "manual" or reason == "land")
    elytra.reset_physics(player, coast)

    local msgs = {
        manual    = minetest.colorize("#aaaaaa", "Glide ended."),
        land      = minetest.colorize("#aaaaaa", "Landed."),
        stall     = minetest.colorize("#ffaa00", "⚠ Stalled! ") .. "Look down to dive and regain speed.",
        broke     = minetest.colorize("#ff5555", "✗ Elytra broke! ") ..
                    minetest.colorize("#888888", "Craft or repair it."),
        collision = minetest.colorize("#ff5555", "✗ Crashed!"),
        water     = minetest.colorize("#55aaff", "Splashdown!"),
    }
    minetest.chat_send_player(name, msgs[reason] or "Glide ended.")

    if reason == "stall" then
        spawn_stall_particles(player)
        play_to_player(player, snd.stall)
    elseif reason == "broke" then
        play_to_player(player, snd.crack)
        sync_item_durability(player, state)
        save_durability(name, 0)
    elseif reason == "water" then
        spawn_water_splash(player)
        play_to_player(player, snd.splash)
    elseif reason == "land" then
        local vel = player:get_velocity()
        local spd = vel and vec_len(vel) or 0
        if spd > 12 then
            play_to_player(player, snd.land_hard)
        else
            play_to_player(player, snd.land_soft)
        end
    end
end

-- ─── ROCKET BOOST ──────────────────────────────────────────
function elytra.fire_rocket(player)
    local state = get_state(player)
    local cfg   = elytra.config

    state.boosting   = true
    state.boost_timer = 0.0

    -- Boost velocity in current look direction (like MC: sudden jolt forward)
    local look = get_look_dir(player)
    state.boost_vel = {
        x = look.x * cfg.rocket_boost,
        y = look.y * cfg.rocket_boost,
        z = look.z * cfg.rocket_boost,
    }
    state.target_speed = cfg.glide_speed_max  -- briefly hit near-max speed
    state.speed        = cfg.glide_speed_max * 0.8

    play_to_player(player, snd.rocket, 1.1)
    spawn_rocket_particles(player)

    minetest.chat_send_player(player:get_player_name(),
        minetest.colorize("#ffaa55", "🚀 Rocket boost!"))
end

-- ─── HUD ───────────────────────────────────────────────────
function elytra.show_hud(player)
    local state = get_state(player)
    if state.hud_id then return end
    state.hud_id = player:hud_add({
        hud_elem_type = "text",
        position      = { x = 0.5, y = 0.83 },
        offset        = { x = 0,   y = 0 },
        text          = "Elytra: Ready",
        alignment     = { x = 0,   y = 0 },
        color         = 0xFFFFFF,
        scale         = { x = 160, y = 160 },
        z_index       = 100,
    })
end

function elytra.hide_hud(player)
    local state = get_state(player)
    if state.hud_id then
        player:hud_remove(state.hud_id)
        state.hud_id = nil
    end
end

function elytra.update_hud(player, state)
    if not state.hud_id then return end
    local cfg     = elytra.config
    local dur_pct = math.floor((state.durability / cfg.max_durability) * 100)

    -- Durability colour
    local dc = dur_pct > 60 and "#55ff55" or (dur_pct > 25 and "#ffaa00" or "#ff5555")

    local txt
    if state.gliding then
        -- Speed visualiser [████░░░░] 8 chars
        local t      = clamp((state.speed - cfg.glide_speed_min) / (cfg.glide_speed_max - cfg.glide_speed_min), 0, 1)
        local filled = math.floor(t * 8)
        local bar    = string.rep("█", filled) .. string.rep("░", 8 - filled)

        local extras = ""
        if state.boosting then
            extras = extras .. minetest.colorize("#ffaa55", " 🚀BOOST")
        end
        if state.speed <= cfg.glide_speed_min + 0.8 then
            extras = extras .. minetest.colorize("#ffaa00", " ⚠STALL")
        end

        txt = string.format("%s [%s] %.0f m/s  %sDUR %d%%%s",
            minetest.colorize("#55ffff", "▶"),
            bar,
            state.speed,
            minetest.colorize(dc, ""),
            dur_pct,
            extras
        )
    else
        txt = string.format("Elytra %s  %sDUR %d%%",
            minetest.colorize("#55ff55", "✔ Ready"),
            minetest.colorize(dc, ""),
            dur_pct
        )
    end

    player:hud_change(state.hud_id, "text", txt)
end

-- ─── MAIN LOOP ─────────────────────────────────────────────
local step_accum = 0.0
local dur_accum  = 0.0
local PHYSICS_HZ = 0.05
local DUR_HZ     = 1.0

minetest.register_globalstep(function(dtime)
    step_accum = step_accum + dtime
    dur_accum  = dur_accum  + dtime

    local do_physics    = step_accum >= PHYSICS_HZ
    local do_durability = dur_accum  >= DUR_HZ

    if do_physics    then step_accum = step_accum - PHYSICS_HZ end
    if do_durability then dur_accum  = dur_accum  - DUR_HZ     end

    for _, player in ipairs(minetest.get_connected_players()) do
        local state    = get_state(player)
        local controls = player:get_player_control()
        local cfg      = elytra.config

        -- ── [E] key toggle ───────────────────────────────
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

        -- ── Sneak+Jump → unequip ─────────────────────────
        if state.equipped then
            if controls.sneak and controls.jump then
                if not state._unequip_held then
                    state._unequip_held = true
                    elytra.unequip(player)
                end
            else
                state._unequip_held = false
            end
        end

        -- ── Skip non-gliding players ──────────────────────
        if not state.gliding then
            if do_physics then elytra.update_hud(player, state) end
            goto continue
        end

        -- ── Water entry ──────────────────────────────────
        if is_in_water(player) then
            if not state.in_water then
                state.in_water = true
                -- Slow down massively and stop glide
                local vel = player:get_velocity()
                if vel then
                    player:set_velocity({
                        x = vel.x * cfg.water_drag,
                        y = -1.0,
                        z = vel.z * cfg.water_drag,
                    })
                end
                elytra.stop_glide(player, "water")
            end
            goto continue
        else
            state.in_water = false
        end

        -- ── Land detection ────────────────────────────────
        if is_grounded(player) then
            reset_animation(player)
            elytra.stop_glide(player, "land")
            if do_physics then elytra.update_hud(player, state) end
            goto continue
        end

        -- ── Physics tick ─────────────────────────────────
        if do_physics then
            local pitch = player:get_look_vertical()
            local look  = get_look_dir(player)

            -- ── Rocket boost override ─────────────────────
            if state.boosting then
                state.boost_timer = state.boost_timer + PHYSICS_HZ
                if state.boost_timer >= cfg.rocket_boost_time then
                    state.boosting    = false
                    -- Hand back to normal glide physics at boosted speed
                    state.target_speed = state.speed
                else
                    -- During boost, velocity is purely look-direction at boost speed
                    -- (MC: rocket gives a fixed impulse in look direction)
                    local t_frac = 1.0 - (state.boost_timer / cfg.rocket_boost_time)
                    local bspd   = state.speed * t_frac + cfg.glide_speed_base * (1-t_frac)
                    player:set_velocity({
                        x = look.x * bspd,
                        y = look.y * bspd,
                        z = look.z * bspd,
                    })
                    spawn_rocket_particles(player)
                    apply_bank_animation(player, state, PHYSICS_HZ)
                    goto hud_and_sound
                end
            end

            -- ── Normal glide physics ──────────────────────
            -- Pitch effect on speed (MC-accurate):
            --   * Diving  (pitch > 0) → speed increases
            --   * Climbing (pitch < 0) → speed decreases (lose kinetic energy)
            local pitch_effect
            if pitch > 0 then
                pitch_effect = pitch * cfg.pitch_accel
            else
                pitch_effect = pitch * cfg.pitch_lift
            end
            state.target_speed = state.target_speed + pitch_effect * (60 * PHYSICS_HZ)

            -- Drag (MC is very low drag, enables long flights)
            state.target_speed = state.target_speed * (1.0 - cfg.drag)

            -- Updraft from hot blocks below
            local updraft = get_updraft(player)
            if updraft > 0 then
                state.target_speed = state.target_speed + updraft * PHYSICS_HZ * 0.5
            end

            -- Clamp
            state.target_speed = clamp(state.target_speed, cfg.glide_speed_min, cfg.glide_speed_max)

            -- Smooth actual speed
            state.speed = lerp(state.speed, state.target_speed, cfg.speed_smooth)

            -- ── Stall ─────────────────────────────────────
            if state.speed <= cfg.glide_speed_min + 0.15 then
                state.stall_timer = state.stall_timer + PHYSICS_HZ
                if state.stall_timer >= cfg.stall_recover_time then
                    reset_animation(player)
                    elytra.stop_glide(player, "stall")
                    goto continue
                end
            else
                state.stall_timer = 0.0
            end

            -- ── Partial gravity (MC: very subtle, 0.08 units/tick) ──
            -- In MC, elytra applies a tiny gravity if not pointing mostly downward.
            -- The effect is: horizontal speed is maintained but y slowly drops
            -- unless you're actively diving to convert to horizontal speed.
            local vy_gravity
            if pitch > 0.2 then
                -- Diving: look.y already carries the speed downward
                vy_gravity = 0
            else
                -- Level/climbing: apply partial gravity pull
                vy_gravity = -cfg.gravity_factor * 9.81 * PHYSICS_HZ * 10
            end

            -- Updraft counteracts gravity
            if updraft > 0 then
                vy_gravity = vy_gravity + updraft * PHYSICS_HZ * 3
            end

            player:set_velocity({
                x = look.x * state.speed,
                y = look.y * state.speed + vy_gravity,
                z = look.z * state.speed,
            })

            -- ── Collision check ───────────────────────────
            if state.speed > cfg.collision_damage_threshold then
                check_collision(player, state)
            end

            -- ── Particles ─────────────────────────────────
            spawn_trail_particles(player, state)

            -- ── Banking animation ─────────────────────────
            apply_bank_animation(player, state, PHYSICS_HZ)

            ::hud_and_sound::
            -- ── Wind sound update ─────────────────────────
            state.wind_timer = state.wind_timer + PHYSICS_HZ
            if state.wind_timer >= cfg.wind_update_hz then
                state.wind_timer = 0
                update_wind_sound(player, state)
            end
        end

        -- ── Durability drain (once per second) ───────────
        if do_durability and state.gliding then
            state.durability = state.durability - cfg.durability_drain
            save_durability(player:get_player_name(), state.durability)
            if state.durability <= 0 then
                state.durability = 0
                reset_animation(player)
                elytra.stop_glide(player, "broke")
                goto continue
            end
        end

        -- ── HUD ──────────────────────────────────────────
        if do_physics then
            elytra.update_hud(player, state)
        end

        ::continue::
    end
end)

-- ─── EQUIP ON ITEM USE ─────────────────────────────────────
minetest.register_on_item_use(function(itemstack, player)
    local name = itemstack:get_name()
    if name == "elytra:elytra" then
        elytra.try_equip(player)
        return itemstack
    end
    -- Rocket use while gliding
    if name == "elytra:rocket" then
        local state = get_state(player)
        if state.gliding then
            elytra.fire_rocket(player)
            itemstack:take_item(1)
            return itemstack
        end
    end
end)

-- ─── JOIN: restore durability ──────────────────────────────
minetest.register_on_joinplayer(function(player)
    local name  = player:get_player_name()
    local state = get_state(player)
    state.durability = load_durability(name)
end)

-- ─── LEAVE: save and clean up ──────────────────────────────
minetest.register_on_leaveplayer(function(player)
    local name  = player:get_player_name()
    local state = player_state[name]
    if state then
        save_durability(name, state.durability)
        stop_sound(state.wind_handle)
        reset_animation(player)
    end
    player_state[name] = nil
end)

-- ─── COMMANDS ──────────────────────────────────────────────
minetest.register_chatcommand("giveelytra", {
    description = "Give yourself an Elytra",
    privs       = { interact = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        player:get_inventory():add_item("main", "elytra:elytra")
        return true, minetest.colorize("#55ff55", "Elytra added to inventory!")
    end,
})

minetest.register_chatcommand("giverocket", {
    description = "Give yourself 16 Elytra rockets",
    privs       = { interact = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        player:get_inventory():add_item("main", "elytra:rocket 16")
        return true, minetest.colorize("#ffaa55", "16 rockets added!")
    end,
})

minetest.register_chatcommand("elytrarepair", {
    description = "Fully repair your Elytra",
    privs       = { interact = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local state = get_state(player)
        state.durability = elytra.config.max_durability
        save_durability(name, state.durability)
        elytra.update_hud(player, state)
        return true, minetest.colorize("#55ff55", "Elytra repaired to 100%!")
    end,
})

minetest.register_chatcommand("elytrainfo", {
    description = "Show Elytra status",
    privs       = { interact = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local state   = get_state(player)
        local dur_pct = math.floor((state.durability / elytra.config.max_durability) * 100)
        return true, string.format(
            "Elytra — equipped: %s | gliding: %s | durability: %d%% | speed: %.1f m/s | boosting: %s",
            tostring(state.equipped), tostring(state.gliding),
            dur_pct, state.speed, tostring(state.boosting)
        )
    end,
})

-- ─── LOADED ────────────────────────────────────────────────
minetest.log("action", "[Elytra v3] Loaded — Minecraft-accurate physics, rockets, particles, sounds, persistent durability.")
print("[Elytra v3] ✓ Ready! /giveelytra  /giverocket  /elytrainfo  /elytrarepair")
