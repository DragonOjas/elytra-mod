

local elytra_physics = {
    glide_speed = 18,       
    fall_speed = -2,      
    pitch_boost = 2.5,     
    wear_speed = 10         
}


minetest.register_tool("elytra:elytra", {
    description = "Elytra Wings",
    inventory_image = "elytra_icon.png", 
    groups = {armor_torso = 1, physics_elytra = 1},
    stack_max = 1,
})


minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        local inv = player:get_inventory()
        local item = inv:get_stack("main", player:get_wield_index()) 
        
       
        local is_wearing = inv:contains_item("main", "elytra:elytra")
        local controls = player:get_player_control()
        local vel = player:get_velocity()

        
        if is_wearing and vel.y < -1.5 and controls.jump then
            local pitch = player:get_look_vertical()
            local dir = player:get_look_dir()
            
         
            local speed = elytra_physics.glide_speed + (pitch * elytra_physics.pitch_boost)
            
            
            player:set_velocity({
                x = dir.x * speed,
                y = math.max(vel.y, elytra_physics.fall_speed - pitch),
                z = dir.z * speed
            })

          
            player:set_properties({
                mesh = "elytra.b3d", 
                visual = "mesh",
                textures = {"elytra_texture.png"}, -
            })

          
            player:set_animation({x=20, y=40}, 30, 0)

            if math.random(1, 100) > 95 then
                local stack = inv:get_stack("main", 1) 
                stack:add_wear(elytra_physics.wear_speed)
                inv:set_stack("main", 1, stack)
            end
        else
            player:set_properties({
                mesh = "character.b3d", 
                visual = "mesh",
            })
        end
    end
end)

minetest.log("action", "[Elytra] Mod Loaded Successfully!")
