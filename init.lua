-- Elytra Mod for Luanti
-- This script handles physics, animations, and item registration

local elytra_physics = {
    glide_speed = 18,       -- How fast you glide forward
    fall_speed = -2,        -- How slow you fall while gliding
    pitch_boost = 2.5,      -- How much speed you gain looking down
    wear_speed = 10         -- How fast the wings take damage
}

-- 1. Register the Elytra Item
minetest.register_tool("elytra:elytra", {
    description = "Elytra Wings",
    inventory_image = "elytra_icon.png", -- Needs to be in textures/
    groups = {armor_torso = 1, physics_elytra = 1},
    stack_max = 1,
})

-- 2. The Main Physics Loop
minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        local inv = player:get_inventory()
        local item = inv:get_stack("main", player:get_wield_index()) -- Checks held item or armor
        
        -- Check if player is "wearing" it (you can change this to look at armor slots)
        local is_wearing = inv:contains_item("main", "elytra:elytra")
        local controls = player:get_player_control()
        local vel = player:get_velocity()

        -- Trigger Glide: Falling + Pressing Jump
        if is_wearing and vel.y < -1.5 and controls.jump then
            local pitch = player:get_look_vertical()
            local dir = player:get_look_dir()
            
            -- Calculate Speed based on Pitch
            -- Looking down (positive pitch) increases speed
            local speed = elytra_physics.glide_speed + (pitch * elytra_physics.pitch_boost)
            
            -- Apply Velocity
            player:set_velocity({
                x = dir.x * speed,
                y = math.max(vel.y, elytra_physics.fall_speed - pitch),
                z = dir.z * speed
            })

            -- 3. Update Visuals & Animation
            player:set_properties({
                mesh = "elytra.b3d", -- Needs to be in models/
                visual = "mesh",
                textures = {"elytra_texture.png"}, -- Needs to be in textures/
            })

            -- Play gliding animation (usually frames 20 to 40 in most models)
            -- Change these numbers to match your .b3d file
            player:set_animation({x=20, y=40}, 30, 0)

            -- 4. Apply Wear (Damage the wings over time)
            if math.random(1, 100) > 95 then
                local stack = inv:get_stack("main", 1) -- Example slot
                stack:add_wear(elytra_physics.wear_speed)
                inv:set_stack("main", 1, stack)
            end
        else
            -- Reset to normal player model if not gliding
            player:set_properties({
                mesh = "character.b3d", -- Default Luanti model
                visual = "mesh",
            })
        end
    end
end)

minetest.log("action", "[Elytra] Mod Loaded Successfully!")
