-- Elytra Pro Mod for Luanti
-- Features: Aerodynamics, Durability, HUD, and Particles

local elytra = {
    gliding_players = {},
    update_timer = 0,
    MAX_DURABILITY = 500,
}

-- 1. Register the Item
minetest.register_tool("elytra:wings", {
    description = "Elytra Wings (Pro)\nLook down to dive, up to stall.",
    inventory_image = "elytra_item.png",
    groups = {tool = 1},
    tool_capabilities = {
        full_punch_interval = 1.0,
        max_drop_level = 0,
    },
})

-- 2. Helper: Stop Gliding
local function stop_gliding(player)
    local name = player:get_player_name()
    if elytra.gliding_players[name] then
        elytra.gliding_players[name] = nil
        player:set_physics_override({gravity = 1.0})
        player_api.set_animation(player, "stand")
        
        -- Remove HUD
        if player:hud_get(elytra.gliding_players[name .. "_hud"]) then
            player:hud_remove(elytra.gliding_players[name .. "_hud"])
        end
        
        minetest.sound_play("elytra_stop", {object = player, gain = 0.5})
    end
end

-- 3. Particle Effect for Wind
local function spawn_wind_particles(player)
    local pos = player:get_pos()
    local vel = player:get_velocity()
    minetest.add_particle({
        pos = {x = pos.x, y = pos.y + 1.5, z = pos.z},
        velocity = {x = -vel.x * 0.2, y = -vel.y * 0.2, z = -vel.z * 0.2},
        acceleration = {x = 0, y = 0, z = 0},
        expirationtime = 0.5,
        size = 1,
        collisiondetection = false,
        texture = "elytra_particle.png", -- Create a small white blur texture
        glow = 5,
    })
end

-- 4. Main Engine (Globalstep)
minetest.register_globalstep(function(dtime)
    elytra.update_timer = elytra.update_timer + dtime
    
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        local controls = player:get_player_control()
        local vel = player:get_velocity()
        local item = player:get_wielded_item()
        local is_wielding = (item:get_name() == "elytra:wings")
        
        -- Logic to START gliding
        if is_wielding and vel.y < -3.0 and controls.jump and not elytra.gliding_players[name] then
            -- Durability Check
            if item:get_wear() < 65000 then 
                elytra.gliding_players[name] = {speed = 10}
                player:set_physics_override({gravity = 0})
                player_api.set_animation(player, "lay")
                
                -- Create HUD for Speed
                elytra.gliding_players[name .. "_hud"] = player:hud_add({
                    hud_elem_type = "text",
                    position = {x = 0.5, y = 0.8},
                    offset = {x = 0, y = 0},
                    text = "Airspeed: 0 m/s",
                    number = 0xFFFFFF,
                    scale = {x = 100, y = 20},
                })
                
                minetest.sound_play("elytra_wind", {object = player, loop = true, gain = 0.3})
            end
        end

        -- Logic DURING flight
        if elytra.gliding_players[name] then
            -- 1. Check if we should stop
            local pos = player:get_pos()
            local node_below = minetest.get_node({x=pos.x, y=pos.y-0.5, z=pos.z})
            
            if not is_wielding or controls.sneak or minetest.registered_nodes[node_below.name].walkable then
                stop_gliding(player)
            else
                -- 2. Advanced Flight Physics
                local look_dir = player:get_look_dir()
                local pitch = player:get_look_vertical() -- Up is negative, Down is positive in Luanti API
                
                -- Speed logic: Diving (pitch > 0) adds speed. Climbing (pitch < 0) removes it.
                local current_speed = elytra.gliding_players[name].speed
                
                if pitch > 0.2 then -- Diving
                    current_speed = math.min(current_speed + (pitch * 15 * dtime), 40)
                elseif pitch < -0.2 then -- Climbing
                    current_speed = math.max(current_speed + (pitch * 20 * dtime), 0)
                else -- Level flight drag
                    current_speed = math.max(current_speed - (0.5 * dtime), 5)
                end
                
                elytra.gliding_players[name].speed = current_speed
                
                -- Calculate glide slope
                -- If speed is too low, player "stalls" and drops
                local fall_modifier = 1.2
                if current_speed < 8 then
                    fall_modifier = 6.0 -- Stall
                end
                
                player:set_velocity({
                    x = look_dir.x * current_speed,
                    y = (look_dir.y * current_speed) - fall_modifier,
                    z = look_dir.z * current_speed
                })
                
                -- 3. Update Visuals & Wear
                if elytra.update_timer > 0.1 then
                    spawn_wind_particles(player)
                    
                    -- Damage the tool while flying
                    item:add_wear(50)
                    player:set_wielded_item(item)
                    
                    -- Update HUD
                    player:hud_change(elytra.gliding_players[name .. "_hud"], "text", 
                        "Airspeed: " .. math.floor(current_speed) .. " m/s")
                end
            end
        end
    end
    
    if elytra.update_timer > 0.1 then elytra.update_timer = 0 end
end)

-- 5. Chat Commands for debugging
minetest.register_chatcommand("repair_elytra", {
    privs = {give = true},
    func = function(name)
        local player = minetest.get_player_by_name(name)
        local item = player:get_wielded_item()
        if item:get_name() == "elytra:wings" then
            item:set_wear(0)
            player:set_wielded_item(item)
            return true, "Elytra repaired!"
        end
        return false, "Hold the Elytra to repair it."
    end,
})

-- 6. Crafting Recipe
minetest.register_craft({
    output = "elytra:wings",
    recipe = {
        {"default:steel_ingot", "", "default:steel_ingot"},
        {"default:mese_crystal", "default:diamond", "default:mese_crystal"},
        {"default:obsidian_shard", "", "default:obsidian_shard"},
    }
})

-- End of Elytra Mod
