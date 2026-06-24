-- Elytra Mod (Minecraft-style gliding with momentum + durability)
local elytra_active = {}

local function activate_elytra(player)
    if not player or not player:is_player() then return end
    local name = player:get_player_name()
    elytra_active[name] = true
    player:set_physics_override({
        gravity = 0.3,  -- reduced gravity for glide
        speed = 2.0,    -- forward momentum
        jump = 0.0,     -- disable normal jump
    })
    minetest.chat_send_player(name, "Elytra activated! Glide mode on.")
end

local function deactivate_elytra(player)
    if not player or not player:is_player() then return end
    local name = player:get_player_name()
    elytra_active[name] = false
    player:set_physics_override({
        gravity = 1.0,
        speed = 1.0,
        jump = 1.0,
    })
    minetest.chat_send_player(name, "Elytra deactivated.")
end

minetest.register_tool("elytra_mod:elytra", {
    description = "Elytra Wings",
    inventory_image = "elytra.png",
    stack_max = 1,
    wear = 0,

    on_use = function(itemstack, user, pointed_thing)
        if not user or not user:is_player() then return itemstack end
        local name = user:get_player_name()
        if elytra_active[name] then
            deactivate_elytra(user)
        else
            activate_elytra(user)
        end
        return itemstack
    end,
})

-- Apply glide momentum + durability
minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        if elytra_active[name] then
            local vel = player:get_velocity()
            if vel and vel.y < -1 then
                -- Forward momentum (auto-glide without pressing keys)
                player:add_velocity({x = vel.x * 0.05, y = 0, z = vel.z * 0.05})

                -- Durability wear
                local inv = player:get_inventory()
                if inv then
                    local stack = inv:find_item("elytra_mod:elytra")
                    if stack and not stack:is_empty() then
                        stack:add_wear(65535 / 300) -- ~300 glides
                        inv:set_stack("main", inv:get_stack_index(stack), stack)
                        if stack:is_empty() then
                            deactivate_elytra(player)
                            minetest.chat_send_player(name, "Your Elytra broke!")
                        end
                    end
                end
            end
        end
    end
end)

-- Reset physics when leaving
minetest.register_on_leaveplayer(function(player)
    deactivate_elytra(player)
end)
