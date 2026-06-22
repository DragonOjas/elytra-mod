-- ============================================================
--  ELYTRA MOD for Minetest (TechBlox / standard Minetest)
--  Improved: unified step loop, real banking animation,
--  smooth speed, proper grounded check, stall mechanic,
--  persistent durability, corrected look-dir math, HUD polish
-- ============================================================

local elytra = {}

-- ─── CONFIG ────────────────────────────────────────────────
elytra.config = {
    -- Glide physics
    glide_speed_base     = 6.0,    -- starting horizontal speed (m/s)
    glide_speed_max      = 22.0,   -- terminal dive speed
    glide_speed_min      = 2.5,    -- stall speed (below this → drop)
    gravity_factor       = 0.28,   -- partial gravity while gliding
    pitch_accel          = 0.12,   -- acceleration gain per radian of downward pitch
    pitch_lift           = 0.07,   -- decel / lift gain per radian of upward pitch
    drag                 = 0.018,  -- air resistance coefficient per tick
    speed_smooth         = 0.15,   -- lerp factor for speed changes (lower = smoother)
    launch_boost         = 6.0,    -- upward impulse when activating from near-hover
    launch_boost_min_vy  = -3.0,   -- only boost if falling slower than this

    -- Banking animation
    bank_speed           = 0.10,   -- how fast the tilt tracks the turn rate
    bank_max             = 35.0,   -- max visual roll in degrees
    bank_decay           = 0.85,   -- how quickly banking returns to 0

    -- Stall
    stall_recover_time   = 0.6,    -- seconds of stall before auto-stop glide

    -- Durability
    max_durability       = 432,
    durability_drain     = 1,      -- per second while gliding

    -- Ground detection
    ground_check_dist    = 1.1,    -- distance below player origin to check for ground

    -- Controls
    activate_key         = "aux1", -- E key by default in Minetest
}

-- ─── COLOUR HELPER (Minetest chat colour) ──────────────────
-- Minetest uses minetest.colorize() for HUD; for chat we use the escape approach.
local function cc(colour, text)
    return minetest.colorize(colour, text)
end

-- ─── PER-PLAYER STATE ──────────────────────────────────────
local player_state = {}

local function get_state(player)
    local name = player:get_player_name()
    if not player_state[name] then
        player_state[name] = {
            gliding          = false,
            target_speed     = elytra.config.glide_speed_base,
            speed            = elytra.config.glide_speed_base,
            equipped         = false,
            durability       = elytra.config.max_durability,
            hud_id           = nil,
            hud_bar_id       = nil,
            tilt             = 0.0,   -- current banking roll (degrees)
            prev_yaw         = 0.0,   -- for computing yaw delta
            stall_timer      = 0.0,
            _aux1_held       = false,
            _unequip_held    = false,
        }
    end
    return player_state[name]
end

-- ─── ITEM DEFINITION ───────────────────────────────────────
minetest.register_craftitem("elytra:elytra", {
    description = "Elytra\n" ..
        minetest.colorize("#aaffaa", "Wear in chest slot.") .. "\n" ..
        minetest.colorize("#aaaaff", "Jump, then press [E / Aux1] to glide!"),
    inventory_image = "elytra_item.png",
    stack_max       = 1,
    groups          = { armor_torso = 1 },

    on_use = function(itemstack, user, pointed_thing)
        if user then
            elytra.try_equip(user, itemstack)
        end
        return itemstack
    end,
})

-- ─── CRAFT RECIPES ─────────────────────────────────────────
minetest.register_craft({
    output = "elytra:elytra",
    recipe = {
        { "group:stick",   "default:mese_crystal", "group:stick"   },
        { "default:paper", "default:mese_crystal", "default:paper" },
        { "default:paper", "group:stick",          "default:paper" },
    }
})

minetest.register_craft({
    type   = "shapeless",
    output = "elytra:elytra",
    recipe = { "elytra:elytra_damaged", "default:paper", "default:paper" },
})

-- ─── GROUND CHECK ──────────────────────────────────────────
local function is_grounded(player)
    local pos = player:get_pos()
    if not pos then return false end
    local below = minetest.get_node({
        x = pos.x,
        y = pos.y - elytra.config.ground_check_dist,
        z = pos.z,
    })
    local n = below.name
    return n ~= "air" and n ~= "ignore" and n ~= ""
end

-- ─── LOOK DIRECTION ────────────────────────────────────────
-- Minetest: yaw 0 = -Z (north), increases CCW when viewed from above.
-- get_look_horizontal() returns yaw in radians.
-- get_look_vertical()   returns pitch in radians; positive = looking DOWN.
local function get_look_dir(player)
    local yaw   = player:get_look_horizontal()
    local pitch = player:get_look_vertical()
    local cos_p = math.cos(pitch)
    return {
        x =  math.sin(yaw) * cos_p,   -- corrected sign for Minetest axes
        y = -math.sin(pitch),
        z = -math.cos(yaw) * cos_p,
    }
end

-- ─── PHYSICS HELPERS ───────────────────────────────────────
function elytra.reset_physics(player)
    player:set_physics_override({ gravity = 1.0, speed = 1.0, jump = 1.0 })
    -- Zero out velocity properly by setting it directly
    local vel = player:get_velocity()
    if vel then
        player:set_velocity({ x = 0, y = vel.y, z = 0 })  -- keep y so landing feels natural
    end
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- ─── EQUIP / UNEQUIP ───────────────────────────────────────
function elytra.try_equip(player, itemstack)
    local state = get_state(player)
    if state.equipped then
        elytra.unequip(player)
    else
        state.equipped    = true
        state.durability  = elytra.config.max_durability
        state.speed       = elytra.config.glide_speed_base
        state.target_speed = elytra.config.glide_speed_base
        elytra.show_hud(player)
        minetest.chat_send_player(player:get_player_name(),
            minetest.colorize("#55ff55", "Elytra equipped! ") ..
            "Jump, then press [E] mid-air to glide. Sneak+Jump to unequip.")
    end
end

function elytra.unequip(player)
    local state = get_state(player)
    state.equipped = false
    state.gliding  = false
    state.tilt     = 0.0
    elytra.reset_physics(player)
    elytra.hide_hud(player)
    minetest.chat_send_player(player:get_player_name(),
        minetest.colorize("#ff5555", "Elytra unequipped."))
end

-- ─── GLIDE START / STOP ────────────────────────────────────
function elytra.start_glide(player)
    local state = get_state(player)
    if not state.equipped then return end
    if state.durability <= 0 then
        minetest.chat_send_player(player:get_player_name(),
            minetest.colorize("#ff5555", "Your Elytra is broken! Repair it first."))
        return
    end

    state.gliding      = true
    state.stall_timer  = 0.0
    state.target_speed = elytra.config.glide_speed_base
    state.speed        = elytra.config.glide_speed_base
    state.prev_yaw     = player:get_look_horizontal()

    -- Suppress normal movement and gravity (we drive velocity manually)
    player:set_physics_override({ gravity = 0.0, speed = 0.0, jump = 0.0 })

    -- Apply launch boost only if not diving hard already
    local vel = player:get_velocity()
    if vel and vel.y > elytra.config.launch_boost_min_vy then
        player:set_velocity({
            x = vel.x,
            y = vel.y + elytra.config.launch_boost,
            z = vel.z,
        })
    end

    minetest.chat_send_player(player:get_player_name(),
        minetest.colorize("#55ffff", "Gliding! ") ..
        "Look down to dive and accelerate, look up to rise.")
end

function elytra.stop_glide(player, reason)
    local state = get_state(player)
    if not state.gliding then return end
    state.gliding = false
    state.tilt    = 0.0
    elytra.reset_physics(player)

    local msg = "Glide ended."
    if reason == "stall" then
        msg = minetest.colorize("#ffaa00", "Stalled! ") .. "Look down to regain speed."
    elseif reason == "broke" then
        msg = minetest.colorize("#ff5555", "Your Elytra broke! ") ..
              minetest.colorize("#aaaaaa", "Craft a new one or repair it.")
    elseif reason == "land" then
        msg = minetest.colorize("#aaaaaa", "Landed.")
    end
    minetest.chat_send_player(player:get_player_name(), msg)
end

-- ─── HUD ───────────────────────────────────────────────────
function elytra.show_hud(player)
    local state = get_state(player)
    if state.hud_id then return end

    -- Status text
    state.hud_id = player:hud_add({
        hud_elem_type = "text",
        position      = { x = 0.5, y = 0.82 },
        offset        = { x = 0,   y = 0 },
        text          = "Elytra: Ready",
        alignment     = { x = 0, y = 0 },
        color         = 0xFFFFFF,
        scale         = { x = 150, y = 150 },
        z_index       = 100,
    })

    -- Durability bar (statbar element)
    state.hud_bar_id = player:hud_add({
        hud_elem_type = "statbar",
        position      = { x = 0.5, y = 0.87 },
        offset        = { x = -96, y = 0 },
        text          = "elytra_hud_bar.png",  -- needs a 16x16 bar icon in textures
        text2         = "elytra_hud_bar_bg.png",
        number        = 20,  -- out of 20 (like health bar), scaled from durability
        item          = 20,
        direction     = 0,
        size          = { x = 24, y = 24 },
        z_index       = 100,
    })
end

function elytra.hide_hud(player)
    local state = get_state(player)
    if state.hud_id     then player:hud_remove(state.hud_id);     state.hud_id     = nil end
    if state.hud_bar_id then player:hud_remove(state.hud_bar_id); state.hud_bar_id = nil end
end

function elytra.update_hud(player, state)
    if not state.hud_id then return end

    local cfg     = elytra.config
    local dur_pct = math.floor((state.durability / cfg.max_durability) * 100)
    local dur_bar = math.max(0, math.floor((state.durability / cfg.max_durability) * 20))

    -- Choose colour based on durability
    local dur_col
    if dur_pct > 60 then
        dur_col = "#55ff55"
    elseif dur_pct > 25 then
        dur_col = "#ffaa00"
    else
        dur_col = "#ff5555"
    end

    local status_txt
    if state.gliding then
        -- Show speed relative to max as a mini bar [||||    ]
        local spd_frac  = (state.speed - cfg.glide_speed_min) / (cfg.glide_speed_max - cfg.glide_speed_min)
        local bar_len   = 8
        local filled    = math.max(0, math.min(bar_len, math.floor(spd_frac * bar_len)))
        local spd_bar   = string.rep("|", filled) .. string.rep(".", bar_len - filled)
        local stall_warn = (state.speed <= cfg.glide_speed_min + 0.5)
            and minetest.colorize("#ffaa00", " STALL") or ""

        status_txt = string.format(
            "%s  SPD [%s] %.0f m/s  DUR %s%d%%%s",
            minetest.colorize("#55ffff", "▶ GLIDING"),
            spd_bar,
            state.speed,
            minetest.colorize(dur_col, ""),
            dur_pct,
            stall_warn
        )
    else
        status_txt = string.format(
            "Elytra %s  DUR %s%d%%",
            minetest.colorize("#55ff55", "Ready"),
            minetest.colorize(dur_col, ""),
            dur_pct
        )
    end

    player:hud_change(state.hud_id, "text", status_txt)

    if state.hud_bar_id then
        player:hud_change(state.hud_bar_id, "number", dur_bar)
    end
end

-- ─── BANKING ANIMATION ─────────────────────────────────────
-- Minetest doesn't expose per-player bone rotation directly in the base engine,
-- but we can approximate a roll/bank effect by combining set_eye_offset + bone
-- animation where supported, or via player model animation index.
-- Here we store the tilt value and apply it to the bone if the API exists.
local function apply_bank_animation(player, state, dtime)
    local cfg     = elytra.config
    local cur_yaw = player:get_look_horizontal()
    local yaw_delta = cur_yaw - state.prev_yaw

    -- Wrap delta to [-π, π]
    if yaw_delta >  math.pi then yaw_delta = yaw_delta - math.pi * 2 end
    if yaw_delta < -math.pi then yaw_delta = yaw_delta + math.pi * 2 end

    state.prev_yaw = cur_yaw

    -- Target tilt: yaw_delta > 0 = turning left → tilt left (negative roll)
    local target_tilt = -yaw_delta * (180 / math.pi) * 12   -- scale factor
    target_tilt = math.max(-cfg.bank_max, math.min(cfg.bank_max, target_tilt))

    -- Smooth tilt towards target, then decay
    if math.abs(yaw_delta) > 0.001 then
        state.tilt = lerp(state.tilt, target_tilt, cfg.bank_speed)
    else
        state.tilt = state.tilt * cfg.bank_decay
    end

    -- Apply eye offset for a subtle camera roll feeling
    -- (true bone animation requires model support / CSM; this is server-side approx)
    local roll_x = math.sin(math.rad(state.tilt)) * 3.0  -- subtle lateral eye shift
    if player.set_eye_offset then
        player:set_eye_offset(
            { x = roll_x, y = 0, z = 0 },   -- first-person
            { x = roll_x, y = 0, z = 0 }    -- third-person
        )
    end

    -- Set animation frame based on glide state
    -- Standard Minetest player model has these animation ranges:
    -- idle=0, walk=168-187, sit=81-160 (varies by texture pack)
    -- We use run (214-233) to suggest outstretched-wing posture
    if player.set_animation then
        player:set_animation(
            { x = 214, y = 233 },   -- "run" frames — best available for glide pose
            15,                      -- frame speed
            0,                       -- frame blend
            true                     -- loop
        )
    end
end

local function reset_animation(player)
    if player.set_eye_offset then
        player:set_eye_offset({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 })
    end
    if player.set_animation then
        player:set_animation({ x = 0, y = 79 }, 15, 0, true)  -- back to idle/walk
    end
end

-- ─── UNIFIED GLOBAL STEP ───────────────────────────────────
-- Single loop — no redundant iterations.
local step_accum = 0.0
local dur_accum  = 0.0
local PHYSICS_HZ = 0.05   -- 20 Hz
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

        -- ── Aux1 toggle (edge-detected) ──────────────────
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

        -- ── Sneak + Jump → unequip ────────────────────────
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

        -- ── Skip rest if not gliding ──────────────────────
        if not state.gliding then goto continue end

        -- ── Land detection ───────────────────────────────
        if is_grounded(player) then
            reset_animation(player)
            elytra.stop_glide(player, "land")
            elytra.update_hud(player, state)
            goto continue
        end

        -- ── Physics tick ─────────────────────────────────
        if do_physics then
            local pitch = player:get_look_vertical()   -- +down, -up
            local look  = get_look_dir(player)

            -- ── Speed targeting based on pitch ────────────
            -- Diving (pitch > 0): gain speed proportional to pitch
            -- Climbing (pitch < 0): lose speed
            local pitch_effect
            if pitch > 0 then
                pitch_effect =  pitch * cfg.pitch_accel
            else
                pitch_effect =  pitch * cfg.pitch_lift   -- pitch is negative, so this subtracts
            end

            -- Integrate speed target
            state.target_speed = state.target_speed + pitch_effect * (60 * PHYSICS_HZ)

            -- Drag on target speed
            state.target_speed = state.target_speed * (1.0 - cfg.drag)

            -- Clamp target
            state.target_speed = math.max(cfg.glide_speed_min,
                                  math.min(cfg.glide_speed_max, state.target_speed))

            -- Smooth actual speed toward target (feels more physical)
            state.speed = lerp(state.speed, state.target_speed, cfg.speed_smooth)

            -- ── Stall detection ───────────────────────────
            if state.speed <= cfg.glide_speed_min + 0.1 then
                state.stall_timer = state.stall_timer + PHYSICS_HZ
                if state.stall_timer >= cfg.stall_recover_time then
                    reset_animation(player)
                    elytra.stop_glide(player, "stall")
                    goto continue
                end
            else
                state.stall_timer = 0.0
            end

            -- ── Partial gravity ───────────────────────────
            -- We blend gravity based on how horizontal the look direction is.
            -- Looking straight ahead → near-zero gravity effect (true glide).
            -- Looking steeply down  → more gravity bleed-through.
            local horiz_factor = math.cos(pitch)   -- 1 = level, 0 = vertical
            local gravity_pull = -cfg.gravity_factor * 9.81 * (1.0 - horiz_factor * 0.5)

            -- ── Build velocity ────────────────────────────
            player:set_velocity({
                x = look.x * state.speed,
                y = look.y * state.speed + gravity_pull * PHYSICS_HZ * 5,
                z = look.z * state.speed,
            })

            -- ── Banking animation ─────────────────────────
            apply_bank_animation(player, state, PHYSICS_HZ)
        end

        -- ── Durability drain ─────────────────────────────
        if do_durability then
            state.durability = state.durability - cfg.durability_drain
            if state.durability <= 0 then
                state.durability = 0
                reset_animation(player)
                elytra.stop_glide(player, "broke")
            end
        end

        -- ── HUD update ───────────────────────────────────
        if do_physics then
            elytra.update_hud(player, state)
        end

        ::continue::
    end
end)

-- ─── EQUIP VIA on_use ──────────────────────────────────────
minetest.register_on_item_use(function(itemstack, player, pointed)
    if itemstack:get_name() == "elytra:elytra" then
        local state = get_state(player)
        if not state.equipped then
            state.equipped   = true
            state.durability = elytra.config.max_durability
            elytra.show_hud(player)
            minetest.chat_send_player(player:get_player_name(),
                minetest.colorize("#55ff55", "Elytra equipped! ") ..
                "Jump then press [E] mid-air to glide.")
        end
        return itemstack
    end
end)

-- ─── CLEAN UP ON LEAVE ─────────────────────────────────────
minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    -- Reset visuals before state is cleared
    reset_animation(player)
    player_state[name] = nil
end)

-- ─── CHAT COMMANDS ─────────────────────────────────────────
minetest.register_chatcommand("giveelytra", {
    description = "Give yourself an Elytra (testing)",
    privs       = { interact = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        player:get_inventory():add_item("main", "elytra:elytra")
        return true, minetest.colorize("#55ff55", "Elytra added to your inventory!")
    end,
})

minetest.register_chatcommand("elytrarepair", {
    description = "Fully repair your equipped Elytra",
    privs       = { interact = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local state = get_state(player)
        if not state.equipped then
            return false, "You don't have an Elytra equipped."
        end
        state.durability = elytra.config.max_durability
        elytra.update_hud(player, state)
        return true, minetest.colorize("#55ff55", "Elytra fully repaired!")
    end,
})

minetest.register_chatcommand("elytrainfo", {
    description = "Show your Elytra status",
    privs       = { interact = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local state = get_state(player)
        if not state.equipped then
            return true, "No Elytra equipped."
        end
        local dur_pct = math.floor((state.durability / elytra.config.max_durability) * 100)
        return true, string.format(
            "Elytra: equipped=%s  gliding=%s  durability=%d%%  speed=%.1f m/s",
            tostring(state.equipped), tostring(state.gliding),
            dur_pct, state.speed
        )
    end,
})

-- ─── DONE ──────────────────────────────────────────────────
minetest.log("action", "[Elytra] Loaded — improved physics, banking, unified step loop.")
print("[Elytra] ✓ Loaded! /giveelytra to test, /elytrainfo for status.")
