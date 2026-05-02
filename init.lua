local elytra_physics = {
    terminal_velocity = -10,
    glide_speed = 15,
    pitch_factor = 2.0
}

minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        local inventory = player:get_inventory()
        
        -- Check if player is wearing elytra (adjust slot name as needed)
        local wearing_elytra = inventory:contains_item("main", "elytra:elytra")
        local control = player:get_player_control()
        local vel = player:get_velocity()

        if wearing_elytra and not player:get_attach() then
            -- Trigger glide if falling and pressing jump
            if vel.y < -2 and control.jump then
                -- Calculate Pitch (Look angle)
                local look_pitch = player:get_look_vertical() 
                
                -- Physics: Gliding Logic
                -- Forward speed increases as you aim down, decreases as you aim up
                local forward_speed = elytra_physics.glide_speed - (look_pitch * elytra_physics.pitch_factor)
                local dir = player:get_look_dir()
                
                player:set_velocity({
                    x = dir.x * forward_speed,
                    y = dir.y * forward_speed,
                    z = dir.z * forward_speed
                })

                -- Animation Handling
                -- Replace 'fly_anim' with your actual animation name in the model
                player:set_properties({
                    mesh = "character_elytra.b3d",
                    visual_size = {x=1, y=1},
                })
            end
        end
    end
end)

-- Register the Item
minetest.register_tool("elytra:elytra", {
    description = "Elytra Wings",
    inventory_image = "elytra_inv.png",
    groups = {armor_torso = 1, physics_elytra = 1},
})
