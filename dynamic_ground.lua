--[[
dynamic_ground.lua
--------------------
This script simulates dynamic changes to ground material properties for MUD and SAND
in BeamNG.drive. It allows for effects like tires digging into soft surfaces,
reducing grip and increasing depth, with a gradual recovery of the ground to its
original state over time.

The script manages its own representation of MUD and SAND parameters and provides
a main update function to be called by BeamNG's Lua environment, typically during
a physics update.

IMPORTANT: This script modifies Lua tables that *represent* ground parameters.
Actual application of these parameters to the BeamNG physics engine requires
additional engine-specific Lua API calls, as detailed in the integration
instructions at the end of this file. The accuracy of MUD/SAND detection
heavily relies on the correct implementation of `M:getMaterialNameById()`.
--]]

-- Module table 'M' encapsulates all public state and functions.
local M = {}

-- Holds the original, unmodified parameters for MUD and SAND.
-- These are used as a baseline for dynamic modifications and for the recovery process.
-- Structure mirrors BeamNG's groundmodel JSON format for relevant parameters.
local originalGroundModelValues = {
  MUD = {
    staticFrictionCoefficient  = 0.55, -- Initial static friction
    slidingFrictionCoefficient = 0.55, -- Initial sliding friction
    hydrodynamicFriction       = 0.01, -- Friction component related to fluid dynamics
    stribeckVelocity           = 6,    -- Velocity at which friction transitions from static to sliding
    strength                   = 1,    -- General strength factor (less used in this script's dynamics)
    roughnessCoefficient       = 0.5,  -- Surface roughness (less used in this script's dynamics)
    fluidDensity               = 7000, -- Density of the material when behaving like a fluid
    flowConsistencyIndex       = 2000, -- Viscosity-like property for fluid behavior
    flowBehaviorIndex          = 0.5,  -- Exponent for non-Newtonian fluid behavior
    dragAnisotropy             = 0.75, -- Directional dependency of drag (less used here)
    shearStrength              = 4000, -- Material's resistance to shear forces (loosens when dug)
    defaultDepth               = 0.15, -- Initial depth of the deformable layer (increases when dug)
    collisionType              = "MUD",  -- BeamNG internal type, MUST NOT be changed dynamically by this script
    skidMarks                  = false   -- Whether this material shows skid marks
  },
  SAND = {
    staticFrictionCoefficient  = 0.6,
    slidingFrictionCoefficient = 0.6,
    hydrodynamicFriction       = 0.02,
    stribeckVelocity           = 6,
    strength                   = 1,
    roughnessCoefficient       = 0.5,
    fluidDensity               = 25000,
    flowConsistencyIndex       = 5000,
    flowBehaviorIndex          = 0.25,
    dragAnisotropy             = 0.5,
    shearStrength              = 12000,
    defaultDepth               = 0.1,
    collisionType              = "SAND",
    skidMarks                  = false
  }
}

-- Utility function to create a deep copy of a table.
-- This is essential for initializing `M.data` from `originalGroundModelValues`
-- without creating a reference, so `originalGroundModelValues` remains pristine.
-- Handles nested tables, but not functions or userdata (sufficient for parameter tables).
local function deepcopy(orig_table)
    local orig_type = type(orig_table)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig_table, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig_table)))
    else -- Handles numbers, strings, booleans, etc.
        copy = orig_table
    end
    return copy
end

-- `M.data` stores the CURRENT, dynamically changing parameters for MUD and SAND.
-- It is initialized with a deep copy of `originalGroundModelValues` and is modified
-- by the script's functions. This is the table that would be read to update the game engine.
M.data = {
  MUD = deepcopy(originalGroundModelValues.MUD),
  SAND = deepcopy(originalGroundModelValues.SAND)
}

-- Defines operational limits (min/max) for dynamically modified parameters.
-- This prevents parameters from reaching unrealistic or engine-breaking values.
-- Max values for some parameters are set to their original values to ensure
-- recovery doesn't overshoot and "improve" the ground beyond its initial state.
local parameter_limits = {
  MUD = {
    defaultDepth = { min = 0.05, max = 0.8 }, -- Min depth, Max possible dug-out depth
    shearStrength = { min = 500, max = originalGroundModelValues.MUD.shearStrength }, -- Min strength, Max is original
    staticFrictionCoefficient = { min = 0.1, max = originalGroundModelValues.MUD.staticFrictionCoefficient },
    slidingFrictionCoefficient = { min = 0.1, max = originalGroundModelValues.MUD.slidingFrictionCoefficient },
    hydrodynamicFriction = {min = 0.005, max = 0.05}, -- Can increase beyond original if very churned
    flowConsistencyIndex = {min = 1000, max = 3000} -- Can change from original
  },
  SAND = {
    defaultDepth = { min = 0.02, max = 1.0 },
    shearStrength = { min = 1000, max = originalGroundModelValues.SAND.shearStrength },
    staticFrictionCoefficient = { min = 0.1, max = originalGroundModelValues.SAND.staticFrictionCoefficient },
    slidingFrictionCoefficient = { min = 0.1, max = originalGroundModelValues.SAND.slidingFrictionCoefficient },
    hydrodynamicFriction = {min = 0.01, max = 0.08},
    flowConsistencyIndex = {min = 2000, max = 8000}
  }
}

---
-- Translates a ground material ID to its name (e.g., "MUD", "SAND").
-- **CRITICAL USER TASK:** This function MUST be correctly implemented or adapted
-- for the script to identify MUD and SAND materials. Without correct mapping,
-- dynamic effects will not be applied to these surfaces.
--
-- The current implementation is a PLACEHOLDER with example IDs.
-- Users should:
-- 1. Determine the actual material IDs for MUD, SAND (and potentially others)
--    in their specific BeamNG level or setup. These IDs can vary.
-- 2. Update the conditional logic below with the correct IDs.
-- 3. Alternatively, if a BeamNG API call exists to get material names from IDs
--    (e.g., `core_groundmodelManager.getMaterialNameById(material_id)`),
--    that should be used instead of manual mapping.
--
-- @param self (table) The module instance (M).
-- @param material_id (number) The physics material ID from `wheel_obj.contactMaterialID1`.
-- @return (string) The name of the material or a placeholder if not recognized.
---
function M:getMaterialNameById(material_id)
    -- USER ACTION REQUIRED: Replace placeholder IDs with actual BeamNG material IDs.
    -- These IDs are EXAMPLES ONLY and likely incorrect for your specific setup.
    -- Consult BeamNG documentation, level data, or use in-game tools to find correct IDs.
    if material_id == 10 then return "MUD"  -- EXAMPLE ID for MUD
    elseif material_id == 11 then return "SAND" -- EXAMPLE ID for SAND
    elseif material_id == 0 then return "ASPHALT" -- Asphalt is often ID 0 or 1 but can vary
    -- Add other common materials here if their IDs are known, to reduce "UNKNOWN" messages.
    -- elseif material_id == XX then return "GRASS"
    end
    -- If the ID is not specifically mapped, return a generic name. This helps in debugging
    -- if new, unmapped materials are encountered.
    return "UNKNOWN_MATERIAL_ID_" .. tostring(material_id)
end

---
-- Gradually recovers modified ground parameters in `M.data` towards their
-- original values stored in `originalGroundModelValues`.
--
-- @param self (table) The module instance (M).
-- @param dt (number) Delta time (time since last physics update), used for rate calculations.
---
function M:recover_ground_parameters(dt)
  if not dt or dt <= 0 then dt = 0.016 end
  local recovery_rate_factor = 0.1
  for material_type, current_params in pairs(self.data) do
    if originalGroundModelValues[material_type] then
      local original_params = originalGroundModelValues[material_type]
      local params_to_recover = {
        "defaultDepth", "shearStrength", "staticFrictionCoefficient",
        "slidingFrictionCoefficient", "hydrodynamicFriction", "flowConsistencyIndex"
      }
      for _, param_name in ipairs(params_to_recover) do
        local current_value = current_params[param_name]
        local original_value = original_params[param_name]
        if current_value and original_value and current_value ~= original_value then
          local difference = original_value - current_value
          local change_this_step = difference * recovery_rate_factor * dt
          if math.abs(change_this_step) >= math.abs(difference) then
            current_params[param_name] = original_value
          else
            current_params[param_name] = current_value + change_this_step
          end
        end
      end
    end
  end
end

---
-- Modifies ground parameters in `M.data` based on detected wheel spin,
-- simulating digging and loosening of the material.
--
-- @param self (table) The module instance (M).
-- @param spinning_wheels (table) A list of tables, each representing a wheel
--                                that is spinning significantly. Expected structure:
--                                `{ wheelID (string), materialType (string), slipAmount (number) }`
-- @param dt (number) Delta time, used to scale the effect of spin over time.
---
function M:modify_ground_parameters_on_spin(spinning_wheels, dt)
  if not dt or dt <= 0 then dt = 0.016 end
  for _, wheel_data in ipairs(spinning_wheels) do
    local material_type = wheel_data.materialType
    local ground_params = self.data[material_type]
    local limits = parameter_limits[material_type]
    if ground_params and limits then
      local depth_increase_factor = 0.005 
      local strength_decrease_factor = -50 
      local friction_decrease_factor = -0.01 
      local hydro_friction_increase_factor = 0.0001 
      local flow_consistency_change_factor = 10
      local slip_effect_this_step = wheel_data.slipAmount * dt
      ground_params.defaultDepth = math.max(limits.defaultDepth.min, math.min(limits.defaultDepth.max, ground_params.defaultDepth + (slip_effect_this_step * depth_increase_factor)))
      ground_params.shearStrength = math.max(limits.shearStrength.min, math.min(limits.shearStrength.max, ground_params.shearStrength + (slip_effect_this_step * strength_decrease_factor)))
      ground_params.staticFrictionCoefficient = math.max(limits.staticFrictionCoefficient.min, math.min(limits.staticFrictionCoefficient.max, ground_params.staticFrictionCoefficient + (slip_effect_this_step * friction_decrease_factor)))
      ground_params.slidingFrictionCoefficient = math.max(limits.slidingFrictionCoefficient.min, math.min(limits.slidingFrictionCoefficient.max, ground_params.slidingFrictionCoefficient + (slip_effect_this_step * friction_decrease_factor)))
      if ground_params.hydrodynamicFriction and limits.hydrodynamicFriction then
          local hydro_change = slip_effect_this_step * hydro_friction_increase_factor
          ground_params.hydrodynamicFriction = math.max(limits.hydrodynamicFriction.min, math.min(limits.hydrodynamicFriction.max, ground_params.hydrodynamicFriction + hydro_change))
      end
      if ground_params.flowConsistencyIndex and limits.flowConsistencyIndex then
          local flow_index_change = slip_effect_this_step * flow_consistency_change_factor
          if material_type == "MUD" then
            ground_params.flowConsistencyIndex = math.max(limits.flowConsistencyIndex.min, math.min(limits.flowConsistencyIndex.max, ground_params.flowConsistencyIndex + flow_index_change))
          elseif material_type == "SAND" then
             ground_params.flowConsistencyIndex = math.max(limits.flowConsistencyIndex.min, math.min(limits.flowConsistencyIndex.max, ground_params.flowConsistencyIndex - flow_index_change))
          end
      end
    end
  end
end

---
-- Detects significant tire spin on soft surfaces (MUD or SAND).
-- This function uses common BeamNG API patterns to access vehicle and wheel data.
-- It relies on `self:getMaterialNameById()` to identify relevant ground materials.
--
-- @param self (table) The module instance (M).
-- @return (table) A list of tables, where each entry represents a wheel
--                 that is spinning significantly. Each entry includes:
--                 - `wheelID` (string): Name of the wheel (e.g., 'wheel_fl').
--                 - `materialType` (string): The type of material ('MUD' or 'SAND'),
--                                          as determined by `getMaterialNameById`.
--                 - `slipAmount` (number): The difference between wheel linear velocity
--                                        and vehicle ground speed (m/s).
---
function M:detect_tire_spin_on_soft_surfaces()
    local spinning_wheels = {}
    -- Threshold for "significant" spin (wheel surface speed > vehicle speed + threshold).
    local spin_threshold = 5.0 -- m/s; tune this value based on desired sensitivity.

    -- Get the current player's vehicle object using the global 'be' (BeamEngine) object.
    local veh = be:getPlayerVehicle(0)
    if not veh then
        -- Optional: log this if it's unexpected during gameplay.
        -- log('D', 'DynamicGround', 'No player vehicle found.') 
        return spinning_wheels
    end

    -- Access the vehicle's wheels collection.
    -- `veh.wheels` is assumed to be an array-like table of wheel objects based on common patterns.
    local vehicle_wheels = veh.wheels
    if not vehicle_wheels then
        -- Optional: log this.
        -- log('D', 'DynamicGround', 'Vehicle has no wheels data.')
        return spinning_wheels
    end

    -- Get the vehicle's general speed from `electrics.values.wheelspeed`.
    -- This is a simplification. For higher accuracy, per-wheel ground speed relative
    -- to the chassis would be ideal if easily accessible and performant.
    local vehicle_speed = electrics.values.wheelspeed or 0

    -- Iterate through each wheel of the vehicle.
    for i = 1, #vehicle_wheels do
        local wheel_obj = vehicle_wheels[i]

        if wheel_obj then
            -- Skip wheels that are broken/detached.
            if wheel_obj.isBroken then goto continue_wheel_loop end

            -- Check for valid ground contact:
            -- `contactMaterialID1` (physics ID of the material the wheel is contacting) should be a valid ID (>= 0).
            -- `contactDepth == 0` suggests direct contact, not e.g. deep submersion that might
            -- be handled differently by physics. This condition might need refinement based on
            -- how BeamNG reports contact in various scenarios (e.g., shallow mud vs. deep mud).
            if wheel_obj.contactMaterialID1 and wheel_obj.contactMaterialID1 >= 0 and wheel_obj.contactDepth == 0 then
                -- Translate material ID to a name using our (user-configurable) mapping function.
                -- This is a critical step for identifying MUD and SAND.
                local material_name = self:getMaterialNameById(wheel_obj.contactMaterialID1)

                -- Process only if the identified material is MUD or SAND AND is defined in our `M.data`.
                if (material_name == "MUD" or material_name == "SAND") and self.data[material_name] then
                    -- Consider only wheels that are actively driven by the powertrain (`isPropulsed`).
                    -- Non-propelled wheels can spin (e.g., if locked up during braking), but
                    -- typically don't cause the "digging" effect this script aims to simulate.
                    if wheel_obj.isPropulsed then
                        -- Calculate wheel's linear surface velocity: angular velocity (rad/s) * radius (m).
                        -- `angularVelocity` is from the wheel physics.
                        -- `radius` is the wheel's physical radius.
                        -- Default radius (e.g., 0.3m) used if `wheel_obj.radius` is nil, though unlikely for a valid wheel.
                        local wheel_linear_velocity = (wheel_obj.angularVelocity or 0) * (wheel_obj.radius or 0.3)
                        
                        -- Calculate slip amount relative to vehicle speed.
                        local slip_amount = wheel_linear_velocity - vehicle_speed

                        -- If wheel linear velocity significantly exceeds vehicle speed, it's spinning.
                        if wheel_linear_velocity > vehicle_speed + spin_threshold then
                            table.insert(spinning_wheels, {
                                wheelID = wheel_obj.name, -- Standard BeamNG wheel name (e.g., "wheel_fl", "wheel_rr1")
                                materialType = material_name,
                                slipAmount = slip_amount
                            })
                        end
                    end
                end
            end
        end
        ::continue_wheel_loop:: -- Lua's goto for continuing the loop from a nested conditional.
    end
    return spinning_wheels
end

---
-- Main update function, intended to be called by BeamNG's physics update loop (e.g., `onPhysicsUpdate(dt)`).
-- This function orchestrates the dynamic ground simulation steps:
-- 1. Detects tire spin.
-- 2. Modifies ground parameters if spin is detected.
-- 3. Applies gradual recovery to all dynamic ground parameters.
--
-- @param self (table) The module instance (M).
-- @param dt (number) The delta time from the physics simulation step (time since last call).
---
function M:update_dynamic_ground(dt)
  -- Step 1: Detect wheel spin on soft surfaces using current vehicle & wheel states.
  local spinning_wheels = self:detect_tire_spin_on_soft_surfaces()

  -- Step 2: If significant spin is detected on MUD or SAND, modify their parameters.
  if #spinning_wheels > 0 then
    self:modify_ground_parameters_on_spin(spinning_wheels, dt)
  end

  -- Step 3: Always call recovery function to allow ground to revert to its original state over time.
  self:recover_ground_parameters(dt)

  -- Step 4: (IMPORTANT - CONCEPTUAL) Apply changes to BeamNG Engine.
  -- The parameters in `self.data.MUD` and `self.data.SAND` are now updated in Lua.
  -- To make these changes affect game physics, BeamNG-specific API calls are needed here.
  -- This script *manages the state*; applying it to the engine is a separate integration step.
  -- Example (fictional API calls - consult BeamNG documentation for actual methods):
  --   engine.updateGroundModelProperties('MUD', self.data.MUD)
  --   engine.updateGroundModelProperties('SAND', self.data.SAND)
end

--[[
Example of how BeamNG might load and call this module (conceptual):
-- In a BeamNG Lua extension, vehicle controller, or level script:
-- local dynamicGroundSystem = require('path/to/dynamic_ground') -- Adjust path as needed

-- During a physics update callback (e.g., onPhysicsUpdate(dt) or similar)
-- function onPhysicsUpdate(dt)
--   if dynamicGroundSystem then
--     dynamicGroundSystem:update_dynamic_ground(dt)
--   end
--   -- ... other update logic
-- end

-- To get current ground model data (e.g., for custom UI or other game logic systems)
-- local currentMudParams = dynamicGroundSystem.data.MUD
-- print("Current MUD defaultDepth: " .. currentMudParams.defaultDepth)
]]

return M

--[[
------------------------------------------------------------------------------------------
-- BeamNG Integration and Usage Instructions for dynamic_ground.lua
------------------------------------------------------------------------------------------

This script provides a framework for simulating dynamic changes to ground material
properties (specifically MUD and SAND) based on vehicle wheel spin.

1. Script Placement:
   - Place this file (`dynamic_ground.lua`) within your BeamNG mod structure.
   - Common locations: `/mods/your_mod_name/lua/`, `/scripts/` within a mod, or a level's script directory.

2. Script Loading:
   - Load using `require('path/to/dynamic_ground')` in a relevant BeamNG Lua file
     (e.g., level's main.lua, vehicle extension, global gameplay script).
     The path is relative to BeamNG's Lua execution context.

3. Calling the Update Function:
   - Call `dynamicGroundSystem:update_dynamic_ground(dt)` regularly from a physics
     update callback (e.g., `onPhysicsUpdate(dt)`), where `dynamicGroundSystem` is
     the loaded module and `dt` is the delta time.

     ```lua
     -- Example:
     -- local dynamicGroundSystem = require('your_mod_name/lua/dynamic_ground')
     -- function onPhysicsUpdate(dt)
     --     if dynamicGroundSystem then
     --         dynamicGroundSystem:update_dynamic_ground(dt)
     --     end
     -- end
     ```

4. CRITICAL USER TASK: Implement `M:getMaterialNameById(material_id)`:
   - The function `M:getMaterialNameById(material_id)` in this script is a PLACEHOLDER.
   - **You MUST modify this function** to correctly map BeamNG's physics material IDs
     (integers obtained from `wheel_obj.contactMaterialID1`) to material names
     ("MUD", "SAND", etc.).
   - Without correct mapping, this script CANNOT identify MUD or SAND, and the
     dynamic effects will not work.
   - To find material IDs:
     - Check BeamNG documentation or ground model definition files (e.g., groundmodels.json).
     - Use in-game debugging tools to inspect `wheel_obj.contactMaterialID1` when on known surfaces.
   - Update the `if/elseif` conditions in `M:getMaterialNameById` with the correct IDs.
   - Alternatively, if BeamNG provides a direct API to get material names from IDs
     (e.g., `core_groundmodelManager.getMaterialNameById(id)`), use that API within the function.

5. Dependencies & API Assumptions:
   - This script assumes access to standard BeamNG Lua environment features and common vehicle/wheel properties:
     - `be:getPlayerVehicle(0)`: To get the current player vehicle.
     - `veh.wheels`: A collection (likely array) of wheel objects/tables.
     - Wheel Properties: `name`, `contactMaterialID1`, `contactDepth`, `angularVelocity`,
       `radius`, `isBroken`, `isPropulsed` for each wheel object.
     - `electrics.values.wheelspeed`: For overall vehicle speed.
   - While these patterns are common (e.g., seen in `vehicleController.lua`), the exact structure
     of `veh.wheels` or specific property names might vary slightly with vehicle mods or
     BeamNG updates. Adjust property access if needed.

6. Engine Interaction (Conceptual - IMPORTANT):
   - This script *manages the logic and state* for dynamic ground parameters in Lua tables
     (`M.data.MUD`, `M.data.SAND`).
   - To make these changes affect in-game physics, you must use BeamNG-specific Lua API
     functions to apply these Lua table values to the actual game engine's ground models.
   - This "bridging" step is NOT part of this script and requires consulting BeamNG
     modding documentation for functions like `engine.setGroundModelProperty()` (fictional example)
     or similar APIs that can modify ground properties at runtime.

7. Accessing Modified Data:
   - Current parameters can be read from `dynamicGroundSystem.data.MUD` or `dynamicGroundSystem.data.SAND`.

8. Debugging:
   - Use `print()` statements or BeamNG's Lua console to inspect values (e.g., material IDs,
     `M.data` contents) to verify behavior and troubleshoot the `getMaterialNameById` mapping.

Remember to consult official BeamNG modding documentation and community resources.
------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------
-- Testing Strategy for dynamic_ground.lua
------------------------------------------------------------------------------------------

Once integrated and `M:getMaterialNameById()` is correctly implemented, use these steps
to test the script's functionality within BeamNG:

1.  Prerequisites for Testing:
    *   **Script Loaded:** Confirm `dynamic_ground.lua` is loaded by BeamNG (e.g., using
        `require` in a game script like a level's main.lua or a vehicle extension).
    *   **Update Function Called:** Ensure `M:update_dynamic_ground(dt)` (e.g., via
        `yourLoadedModuleName:update_dynamic_ground(dt)`) is called every physics frame
        from a suitable callback like `onPhysicsUpdate(dt)`.
    *   **`getMaterialNameById` Implemented:** THIS IS CRUCIAL. Verify that
        `M:getMaterialNameById()` has been updated with the correct physics material IDs
        for MUD and SAND specific to your BeamNG level or map setup. Without this,
        no dynamic effects will occur on these surfaces.

2.  Basic MUD/SAND Detection Test:
    *   **Add Logging:** Temporarily add `print()` or `log()` statements:
        *   Inside `M:detect_tire_spin_on_soft_surfaces()`: When `material_name` is
            determined to be "MUD" or "SAND", log the `wheel_obj.name` and `material_name`.
            Example: `log('D', 'DynamicGround', "Wheel " .. wheel_obj.name .. " on " .. material_name)`
        *   Inside `M:update_dynamic_ground()`: Log the contents of the `spinning_wheels`
            table if it's not empty. Example: `if #spinning_wheels > 0 then log('D', 'DynamicGround', "Spinning wheels: " .. serpent.block(spinning_wheels)) end`
            (You might need a `serpent` library or similar for easy table printing, or print manually).
    *   **Test Drive:** Drive onto a known MUD surface, then a known SAND surface.
    *   **Check Logs:** Observe the BeamNG console or log files.
        *   Verify the script correctly identifies when wheels are on MUD or SAND.
        *   Spin the tires on these surfaces (e.g., hold brake and throttle, or accelerate hard).
        *   Confirm the `spinning_wheels` table gets populated with entries for the spinning wheels,
            showing correct material type and slip amount.

3.  Parameter Modification Test (`M.data` Inspection):
    *   **Access Lua Console:** Open BeamNG's Lua console (usually `~` key).
    *   **Inspect `M.data`:** Use commands to print the dynamic parameters. Example:
        `pp(require('your_mod_name/lua/dynamic_ground').data.MUD)`
        (Adjust the path to how you've `require`d the script).
    *   **Perform Test:**
        1. Drive onto a MUD surface.
        2. Spin the tires significantly for several seconds.
        3. Pause the game (if possible while keeping console active) or quickly switch to console.
        4. Inspect `M.data.MUD`.
    *   **Expected Behavior:**
        *   `defaultDepth` should have increased.
        *   `shearStrength`, `staticFrictionCoefficient`, `slidingFrictionCoefficient`
            should have decreased.
        *   Changes should be within the bounds set by `parameter_limits`.
    *   Repeat the test for a SAND surface and inspect `M.data.SAND`.

4.  Parameter Recovery Test:
    *   **Modify Parameters:** Perform the test above to modify parameters for MUD or SAND.
    *   **Cease Spin:** Move the vehicle off the dynamic surface or onto a hard surface,
        or simply stop spinning the tires.
    *   **Observe Recovery:** Periodically inspect `M.data.MUD` (or `M.data.SAND`) using
        the Lua console over time (e.g., every 10-20 seconds of gameplay).
    *   **Expected Behavior:** The parameters that were changed should gradually revert
        towards their original values (as defined in `originalGroundModelValues`).
        The recovery is not instant.

5.  `collisionType` Immutability Check:
    *   While inspecting `M.data.MUD` or `M.data.SAND` during the tests above, also
        confirm that the `collisionType` field has *not* changed from its original
        string value (e.g., "MUD" should remain "MUD"). This script should not alter it.

6.  Troubleshooting Tips:
    *   **MUD/SAND Not Detected:**
        *   This is almost always due to incorrect material IDs in `M:getMaterialNameById()`.
        *   Temporarily add `print(wheel_obj.name, wheel_obj.contactMaterialID1)` inside the
            wheel loop in `M:detect_tire_spin_on_soft_surfaces()` to see the actual
            material ID your vehicle is on. Compare this ID with what you have in
            `M:getMaterialNameById()`.
    *   **Parameters Not Changing (or not enough):**
        *   Verify `M:update_dynamic_ground(dt)` is being called every frame.
        *   Add `print()` statements inside `M:modify_ground_parameters_on_spin` to see
            if it's being triggered and what `slip_amount` values it's receiving.
        *   The `spin_threshold` in `M:detect_tire_spin_on_soft_surfaces()` might be too high.
        *   The `*_factor` values in `M:modify_ground_parameters_on_spin` might be too small.
    *   **Parameters Change Too Quickly/Slowly or Recover Too Quickly/Slowly:**
        *   Adjust the `*_factor` values in `M:modify_ground_parameters_on_spin`.
        *   Adjust `recovery_rate_factor` in `M:recover_ground_parameters`.
    *   **Errors in Console:** Address any Lua errors reported in the console. They often
        point to incorrect property access or logic issues.
------------------------------------------------------------------------------------------
]]
