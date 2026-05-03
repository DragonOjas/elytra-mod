local core = minetest
local get_players = core.get_connected_players
local api_path = core.get_modpath("player_api")

local ELYTRA_ITEM = "elytra:wings"
local tick_timer = 0

core.register_tool(ELYTRA_ITEM, {
    description = "Aero-Wings\nJump while falling to glide.\nSneak to land.",
    inventory_image = "elytra_item.png",
    groups = {tool = 1},
})

local function stop_flight(player)
    if not player or not player:is_player() then return end
    
    local meta = player:get_meta()
    if meta:get_int("is_gliding") == 0 then return end
    
    meta:set_int("is_gliding", 0)
    meta:set_float("glide_speed", 0)
    
    player:set_physics_override({gravity = 1.0})
    
    if api_path then
        player_api.set_animation(player, "stand")
    end
    
    local handle = meta:get_int("wind_snd")
    if handle and handle ~= 0 then
        core.sound_stop(handle)
        meta:set_int("wind_snd", 0)
    end
end

core.register_globalstep(function(dtime)
    -- Guard against dtime being nil (rare engine edge case)
    dtime = dtime or 0.05
    tick_timer = tick_timer + dtime
    
    if tick_timer < 0.05 then return end
    local fx_tick = (tick_timer > 0.2)
    if fx_tick then tick_timer = 0 end

    for _, player in ipairs(get_players()) do
        -- Nil-Guard: Ensure player didn't vanish since the loop started
        if player and player:is_player() then
            local meta = player:get_meta()
            local gliding = meta:get_int("is_gliding") == 1
            local item = player:get_wielded_item()
            local item_name = item and item:get_name() or ""
            local has_wings = (item_name == ELYTRA_ITEM)
            
            -- Sane defaults for velocity and controls
            local vel = player:get_velocity() or {x=0, y=0, z=0}
            local ctrl = player:get_player_control() or {}

            if has_wings and not gliding and (vel.y or 0) < -3.5 and ctrl.jump then
                meta:set_int("is_gliding", 1)
                player:set_physics_override({gravity = 0})
                if api_path then player_api.set_animation(player, "lay") end
                
                local handle = core.sound_play("elytra_wind", {object = player, loop = true, gain = 0.4})
                meta:set_int("wind_snd", handle or 0)
            end

            if gliding then
                local pos = player:get_pos()
                local node = pos and core.get_node_or_nil({x=pos.x, y=pos.y-1, z=pos.z})
                local is_walkable = node and core.registered_nodes[node.name] and core.registered_nodes[node.name].walkable

                if ctrl.sneak or not has_wings or is_walkable then
                    stop_flight(player)
                else
                    local dir = player:get_look_dir() or {x=0, y=0, z=0}
                    local pitch = player:get_look_vertical() or 0
                    local speed = meta:get_float("glide_speed")
                    
                    if speed < 5 then speed = 12 end
                    
                    if pitch > 0.15 then
                        speed = math.min(speed + (pitch * 1.8), 40)
                    elseif pitch < -0.15 then
                        speed = math.max(speed + (pitch * 2.5), 2)
                    else
                        speed = math.max(speed - 0.1, 8)
                    end
                    
                    meta:set_float("glide_speed", speed)

                    local lift = (speed < 10) and 4.0 or 1.2 
                    player:set_velocity({
                        x = (dir.x or 0) * speed,
                        y = ((dir.y or 0) * speed) - lift,
                        z = (dir.z or 0) * speed
                    })

                    if fx_tick then
                        core.add_particle({
                            pos = pos,
                            velocity = {x=0, y=0, z=0},
                            expirationtime = 0.4,
                            size = 1.5,
                            texture = "elytra_particle.png",
                        })
                        item:add_wear(45)
                        player:set_wielded_item(item)
                    end
                end
            end
        end
    end
end)

core.register_on_leaveplayer(function(player)
    stop_flight(player)
end)
