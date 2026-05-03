-- ============================================================
--  ELYTRA MOD for Minetest (not MineClone)
--  Features: Physics gliding, look-direction flight,
--            smooth speed, animation, equip/unequip, HUD
-- ============================================================

local elytra = {}

-- ─── CONFIG ────────────────────────────────────────────────
elytra.config = {
    -- Glide physics
    glide_speed_base     = 6.0,    -- base horizontal speed (m/s)
    glide_speed_max      = 20.0,   -- max speed in a dive
    glide_speed_min      = 3.0,    -- stall speed
    gravity_factor       = 0.25,   -- how much gravity pulls while gliding (fraction)
    pitch_accel          = 0.08,   -- how fast looking down accelerates
    pitch_decel          = 0.04,   -- how fast looking up decelerates / lifts
    drag                 = 0.02,   -- air resistance per tick
    launch_boost         = 8.0,    -- upward boost when activating mid-air
    -- Durability
    max_durability       = 432,
    durability_drain     = 1,      -- durability lost per second of gliding
    -- Controls
    activate_key         = "aux1", -- sprint key (E by default) to toggle glide
    -- Bounce protection
    ground_stop_vel      = 0.5,    -- velocity below which we auto-stop glide
}

-- ─── STATE ─────────────────────────────────────────────────
-- Per-player state table
local player_state = {}

local function get_state(player)
    local name = player:get_player_name()
    if not player_state[name] then
        player_state[name] = {
            gliding        = false,
            speed          = elytra.config.glide_speed_base,
            equipped       = false,
            durability     = elytra.config.max_durability,
            hud_id         = nil,
            last_pitch     = 0,
            tilt_anim      = 0,   -- visual tilt for banking
        }
    end
    return player_state[name]
end

-- ─── ITEM DEFINITION ───────────────────────────────────────
minetest.register_craftitem("elytra:elytra", {
    description = "Elytra\nWear in chest slot, press [Aux1/E] to glide mid-air!",
    inventory_image = "elytra_item.png",
    stack_max = 1,
    groups = { armor_torso = 1 },

    on_use = function(itemstack, user, pointed_thing)
        -- Allow manual equip via right-click too
        if user then
            elytra.try_equip(user, itemstack)
        end
        return itemstack
    end,
})

-- ─── CRAFT RECIPE ──────────────────────────────────────────
minetest.register_craft({
    output = "elytra:elytra",
    recipe = {
        { "group:stick",       "default:mese_crystal",  "group:stick"       },
        { "default:paper",     "default:mese_crystal",  "default:paper"     },
        { "default:paper",     "group:stick",           "default:paper"     },
    }
})

-- Repair recipe
minetest.register_craft({
    type   = "shapeless",
    output = "elytra:elytra",
    recipe = { "elytra:elytra_damaged", "default:paper", "default:paper" },
})

-- ─── EQUIP / UNEQUIP ───────────────────────────────────────
function elytra.try_equip(player, itemstack)
    local state = get_state(player)
    if state.equipped then
        elytra.unequip(player)
    else
        state.equipped   = true
        state.durability = elytra.config.max_durability
        elytra.show_hud(player)
        minetest.chat_send_player(player:get_player_name(),
            "§aElytra equipped! Jump then press [E/Aux1] to glide.")
    end
end

function elytra.unequip(player)
    local state = get_state(player)
    state.equipped = false
    state.gliding  = false
    elytra.reset_physics(player)
    elytra.hide_hud(player)
    minetest.chat_send_player(player:get_player_name(), "§cElytra unequipped.")
end

-- ─── PHYSICS HELPERS ───────────────────────────────────────
function elytra.reset_physics(player)
    -- Restore default Minetest player physics
    player:set_physics_override({
        gravity  = 1.0,
        speed    = 1.0,
        jump     = 1.0,
    })
    -- Clear forced velocity
    player:add_velocity({ x = 0, y = 0, z = 0 })
end

local function get_look_dir(player)
    -- Returns unit vector in the direction the player is looking
    local yaw   = player:get_look_horizontal()  -- radians, 0 = +Z
    local pitch = player:get_look_vertical()    -- radians, positive = looking down
    local cos_p = math.cos(pitch)
    return {
        x = -math.sin(yaw) * cos_p,
        y = -math.sin(pitch),
        z =  math.cos(yaw) * cos_p,
    }
end

-- ─── GLIDE TOGGLE ──────────────────────────────────────────
function elytra.start_glide(player)
    local state = get_state(player)
    if not state.equipped then return end
    if state.durability <= 0 then
        minetest.chat_send_player(player:get_player_name(),
            "§cYour Elytra is broken! Repair it first.")
        return
    end

    state.gliding = true
    state.speed   = elytra.config.glide_speed_base

    -- Kill normal gravity while gliding (we handle it manually)
    player:set_physics_override({
        gravity = 0.0,
        speed   = 0.0,   -- disable WASD movement while gliding
        jump    = 0.0,
    })

    -- Give a small upward launch boost if nearly stationary
    local vel = player:get_velocity()
    if vel and math.abs(vel.y) < 1.0 then
        player:add_velocity({ x = 0, y = elytra.config.launch_boost, z = 0 })
    end

    minetest.chat_send_player(player:get_player_name(), "§bGliding! Look up to rise, look down to dive.")
end

function elytra.stop_glide(player)
    local state = get_state(player)
    state.gliding = false
    elytra.reset_physics(player)
    minetest.chat_send_player(player:get_player_name(), "§7Glide ended.")
end

-- ─── HUD ───────────────────────────────────────────────────
function elytra.show_hud(player)
    local state = get_state(player)
    if state.hud_id then return end
    state.hud_id = player:hud_add({
        hud_elem_type = "text",
        position      = { x = 0.5, y = 0.85 },
        offset        = { x = 0,   y = 0    },
        text          = "Elytra: Ready",
        alignment     = { x = 0, y = 0 },
        color         = 0xFFFFFF,
        scale         = { x = 100, y = 100 },
    })
end

function elytra.hide_hud(player)
    local state = get_state(player)
    if state.hud_id then
        player:hud_remove(state.hud_id)
        state.hud_id = nil
    end
end

function elytra.update_hud(player)
    local state = get_state(player)
    if not state.hud_id then return end

    local dur_pct = math.floor((state.durability / elytra.config.max_durability) * 100)
    local status  = state.gliding and "§bGLIDING" or "§aReady"
    local spd     = state.gliding and string.format(" | Speed: %.1f m/s", state.speed) or ""

    player:hud_change(state.hud_id, "text",
        string.format("Elytra [%s§r] | Durability: %d%%%s", status, dur_pct, spd))
end

-- ─── MAIN PHYSICS LOOP ─────────────────────────────────────
-- Runs every server step for every online player
local step_timer     = 0
local dur_timer      = 0
local STEP_INTERVAL  = 0.05   -- 20 ticks/sec physics update
local DUR_INTERVAL   = 1.0    -- durability drain every 1 second

minetest.register_globalstep(function(dtime)
    step_timer = step_timer + dtime
    dur_timer  = dur_timer  + dtime

    local do_physics  = step_timer  >= STEP_INTERVAL
    local do_durability = dur_timer >= DUR_INTERVAL

    if do_physics  then step_timer = step_timer - STEP_INTERVAL end
    if do_durability then dur_timer = dur_timer - DUR_INTERVAL  end

    for _, player in ipairs(minetest.get_connected_players()) do
        local state = get_state(player)
        if not state.equipped then goto continue end

        -- ── Auto-stop if player lands ──────────────────────
        if state.gliding then
            local vel = player:get_velocity()
            if vel then
                -- Check if player is on ground using node below
                local pos  = player:get_pos()
                local below = minetest.get_node({
                    x = pos.x,
                    y = pos.y - 0.1,
                    z = pos.z
                })
                local grounded = (below.name ~= "air" and below.name ~= "ignore")

                if grounded then
                    elytra.stop_glide(player)
                    goto hud_update
                end
            end
        end

        -- ── Glide physics tick ────────────────────────────
        if state.gliding and do_physics then
            local cfg    = elytra.config
            local look   = get_look_dir(player)
            local pitch  = player:get_look_vertical()   -- + = looking down

            -- Speed update based on pitch
            -- Looking down → accelerate; looking up → decelerate / gain lift
            local pitch_effect = pitch * (pitch > 0 and cfg.pitch_accel or cfg.pitch_decel)
            state.speed = state.speed + pitch_effect * 60 * STEP_INTERVAL

            -- Apply drag
            state.speed = state.speed * (1.0 - cfg.drag)

            -- Clamp speed
            state.speed = math.max(cfg.glide_speed_min, math.min(cfg.glide_speed_max, state.speed))

            -- Gravity component (partial, makes it feel like gliding not flying)
            local gravity_pull = -cfg.gravity_factor * 9.81

            -- Build velocity vector: forward in look direction + gentle gravity
            local new_vel = {
                x = look.x * state.speed,
                y = look.y * state.speed + gravity_pull * STEP_INTERVAL * 5,
                z = look.z * state.speed,
            }

            player:set_velocity(new_vel)
        end

        -- ── Durability drain ─────────────────────────────
        if state.gliding and do_durability then
            state.durability = state.durability - elytra.config.durability_drain
            if state.durability <= 0 then
                state.durability = 0
                elytra.stop_glide(player)
                minetest.chat_send_player(player:get_player_name(),
                    "§cYour Elytra broke! §7(Craft a new one or repair it)")
            end
        end

        ::hud_update::
        -- ── HUD refresh ───────────────────────────────────
        if do_physics then
            elytra.update_hud(player)
        end

        ::continue::
    end
end)

-- ─── AUX1 (E key) → toggle glide ──────────────────────────
minetest.register_on_player_receive_fields(function(player, formname, fields)
    -- This catches the Aux1 key from a formspec, but we use the movement API below
end)

-- Minetest 5.3+ supports detecting Aux1 via player controls
minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local state    = get_state(player)
        if not state.equipped then goto skip end

        local controls = player:get_player_control()

        -- Aux1 pressed = E key by default
        if controls.aux1 then
            -- Only toggle once per press (edge detection)
            if not state._aux1_held then
                state._aux1_held = true

                -- Must be in air to start gliding
                local pos   = player:get_pos()
                local below = minetest.get_node({ x = pos.x, y = pos.y - 0.6, z = pos.z })
                local in_air = (below.name == "air" or below.name == "ignore")

                if not state.gliding and in_air then
                    elytra.start_glide(player)
                elseif state.gliding then
                    elytra.stop_glide(player)
                end
            end
        else
            state._aux1_held = false
        end

        ::skip::
    end
end)

-- ─── EQUIP VIA INVENTORY (punch item = equip) ─────────────
minetest.register_on_item_use(function(itemstack, player, pointed)
    if itemstack:get_name() == "elytra:elytra" then
        local state = get_state(player)
        if not state.equipped then
            state.equipped   = true
            state.durability = elytra.config.max_durability
            elytra.show_hud(player)
            minetest.chat_send_player(player:get_player_name(),
                "§aElytra equipped! Jump then press [E] mid-air to glide.")
        end
        return itemstack
    end
end)

-- ─── SNEAK + JUMP = unequip ────────────────────────────────
minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local state    = get_state(player)
        if not state.equipped then goto skip2 end

        local controls = player:get_player_control()
        if controls.sneak and controls.jump then
            if not state._unequip_held then
                state._unequip_held = true
                elytra.unequip(player)
            end
        else
            state._unequip_held = false
        end
        ::skip2::
    end
end)

-- ─── CLEAN UP ON LEAVE ─────────────────────────────────────
minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    player_state[name] = nil
end)

-- ─── GIVE COMMAND (for testing) ───────────────────────────
minetest.register_chatcommand("giveelytra", {
    description = "Give yourself an Elytra",
    privs = { interact = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local inv = player:get_inventory()
        inv:add_item("main", "elytra:elytra")
        return true, "§aElytra added to your inventory!"
    end,
})

minetest.log("action", "[Elytra Mod] Loaded successfully!")
print("[Elytra Mod] ✓ Elytra mod loaded! Use /giveelytra to test.")
