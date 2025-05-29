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
instructions at the end of this file.
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
-- Gradually recovers modified ground parameters in `M.data` towards their
-- original values stored in `originalGroundModelValues`.
--
-- @param self (table) The module instance (M).
-- @param dt (number) Delta time (time since last physics update), used for rate calculations.
---
function M:recover_ground_parameters(dt)
  -- Default dt if not provided or invalid, assuming roughly 60 FPS.
  if not dt or dt <= 0 then dt = 0.016 end

  -- Recovery rate factor: determines how quickly parameters revert.
  -- e.g., 0.1 means ~10% of the difference is recovered per second.
  -- Smaller values lead to slower recovery.
  local recovery_rate_factor = 0.1

  -- Iterate through each material type (MUD, SAND) in the dynamic data.
  for material_type, current_params in pairs(self.data) do
    if originalGroundModelValues[material_type] then
      local original_params = originalGroundModelValues[material_type]

      -- List of parameters that are subject to dynamic changes and recovery.
      local params_to_recover = {
        "defaultDepth", "shearStrength", "staticFrictionCoefficient",
        "slidingFrictionCoefficient", "hydrodynamicFriction", "flowConsistencyIndex"
      }

      for _, param_name in ipairs(params_to_recover) do
        local current_value = current_params[param_name]
        local original_value = original_params[param_name]

        -- Proceed if the parameter exists and is different from its original value.
        if current_value and original_value and current_value ~= original_value then
          local difference = original_value - current_value
          -- Calculate change for this step, proportional to difference, rate factor, and dt.
          local change_this_step = difference * recovery_rate_factor * dt

          -- Apply change, ensuring it doesn't overshoot the original value.
          if math.abs(change_this_step) >= math.abs(difference) then
            -- If the change would overshoot, just set to original.
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
    local ground_params = self.data[material_type] -- Current parameters for this material.
    local limits = parameter_limits[material_type] -- Min/max limits for this material.

    if ground_params and limits then
      -- Tuning factors: determine how much each unit of slip (slipAmount * dt) affects parameters.
      -- These values would likely require careful tuning for desired gameplay effect.
      local depth_increase_factor = 0.005 -- e.g., defaultDepth increases by this much per m/s of slip per second.
      local strength_decrease_factor = -50 -- shearStrength decreases.
      local friction_decrease_factor = -0.01 -- Friction coefficients decrease.
      local hydro_friction_increase_factor = 0.0001 -- Hydrodynamic friction might increase.
      local flow_consistency_change_factor = 10 -- Flow consistency might change.

      -- Total effect of slip for this step.
      local slip_effect_this_step = wheel_data.slipAmount * dt

      -- 1. Modify defaultDepth (digging deeper)
      local depth_change = slip_effect_this_step * depth_increase_factor
      ground_params.defaultDepth = math.max(limits.defaultDepth.min, math.min(limits.defaultDepth.max, ground_params.defaultDepth + depth_change))

      -- 2. Modify shearStrength (loosening material)
      local strength_change = slip_effect_this_step * strength_decrease_factor
      ground_params.shearStrength = math.max(limits.shearStrength.min, math.min(limits.shearStrength.max, ground_params.shearStrength + strength_change))

      -- 3. Modify friction coefficients (making it more slippery)
      local friction_change = slip_effect_this_step * friction_decrease_factor
      ground_params.staticFrictionCoefficient = math.max(limits.staticFrictionCoefficient.min, math.min(limits.staticFrictionCoefficient.max, ground_params.staticFrictionCoefficient + friction_change))
      ground_params.slidingFrictionCoefficient = math.max(limits.slidingFrictionCoefficient.min, math.min(limits.slidingFrictionCoefficient.max, ground_params.slidingFrictionCoefficient + friction_change))

      -- 4. Modify hydrodynamicFriction
      if ground_params.hydrodynamicFriction and limits.hydrodynamicFriction then
          local hydro_change = slip_effect_this_step * hydro_friction_increase_factor
          ground_params.hydrodynamicFriction = math.max(limits.hydrodynamicFriction.min, math.min(limits.hydrodynamicFriction.max, ground_params.hydrodynamicFriction + hydro_change))
      end

      -- 5. Modify flowConsistencyIndex (material behaves more/less like a thick fluid)
      if ground_params.flowConsistencyIndex and limits.flowConsistencyIndex then
          local flow_index_change = slip_effect_this_step * flow_consistency_change_factor
          -- Behavior might differ: MUD might get "thicker" (more resistant), SAND looser.
          if material_type == "MUD" then
            ground_params.flowConsistencyIndex = math.max(limits.flowConsistencyIndex.min, math.min(limits.flowConsistencyIndex.max, ground_params.flowConsistencyIndex + flow_index_change))
          elseif material_type == "SAND" then
             ground_params.flowConsistencyIndex = math.max(limits.flowConsistencyIndex.min, math.min(limits.flowConsistencyIndex.max, ground_params.flowConsistencyIndex - flow_index_change))
          end
      end
      -- IMPORTANT: collisionType parameter is intentionally NOT changed here or elsewhere
      -- as it's a fundamental BeamNG property.
    else
      -- This warning indicates a mismatch or missing definition, e.g. if a new material type was
      -- reported by detect_tire_spin but not defined in `originalGroundModelValues` or `parameter_limits`.
      print("Warning: Could not find ground parameters or limits for material: " .. material_type)
    end
  end
end

---
-- Detects significant tire spin on soft surfaces (MUD or SAND).
-- This function is CONCEPTUAL and uses placeholder data for wheels and their states.
-- In a real BeamNG integration, this would use API calls to get:
--   - List of vehicle wheels.
--   - Ground material under each wheel.
--   - Wheel linear velocity (surface speed).
--   - Vehicle's true ground speed at the wheel's contact point.
--
-- @param self (table) The module instance (M).
-- @return (table) A list of tables, where each entry represents a wheel
--                 that is spinning significantly. Each entry includes:
--                 - `wheelID` (string): Identifier for the wheel (e.g., 'front_left').
--                 - `materialType` (string): The type of material ('MUD' or 'SAND').
--                 - `slipAmount` (number): The difference between wheel linear velocity
--                                        and vehicle ground speed (m/s).
---
function M:detect_tire_spin_on_soft_surfaces()
  local spinning_wheels = {}
  -- Threshold for "significant" spin: wheel surface speed must exceed vehicle speed by this much (m/s).
  local spin_threshold = 2.0

  -- CONCEPTUAL: Replace with actual BeamNG API calls.
  -- Example: local wheels_raw = vehicle.getWheelsData() -- Fictional API
  local conceptual_wheels_data = {
    { id = 'wheel_fl', name = 'front_left', contactMaterial = "MUD",  linearVelocity = 5.5, vehicleSpeedAtWheel = 1.0 },
    { id = 'wheel_fr', name = 'front_right',contactMaterial = "ASPHALT",linearVelocity = 2.0, vehicleSpeedAtWheel = 2.0 },
    { id = 'wheel_rl', name = 'rear_left',  contactMaterial = "SAND", linearVelocity = 6.0, vehicleSpeedAtWheel = 1.5 },
    { id = 'wheel_rr', name = 'rear_right', contactMaterial = "MUD",  linearVelocity = 3.0, vehicleSpeedAtWheel = 2.5 } -- Less spin
  }

  for _, wheel_data in ipairs(conceptual_wheels_data) do
    local material_name = wheel_data.contactMaterial

    -- Check if the material is one we handle (MUD or SAND) by seeing if it exists in our data.
    if material_name and self.data[material_name] then
      local wheel_linear_velocity = wheel_data.linearVelocity
      local vehicle_ground_speed = wheel_data.vehicleSpeedAtWheel

      if wheel_linear_velocity and vehicle_ground_speed then
        local slip_amount = wheel_linear_velocity - vehicle_ground_speed
        if slip_amount > spin_threshold then
          table.insert(spinning_wheels, {
            wheelID = wheel_data.name,
            materialType = material_name,
            slipAmount = slip_amount
          })
        end
      else
        -- Log warning if velocity data is missing for a wheel on a relevant surface.
        print("Warning: Missing velocity data for wheel " .. wheel_data.name .. " on " .. material_name)
      end
    end
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
  -- Step 1: Detect wheel spin on soft surfaces.
  -- This uses conceptual data; replace with real BeamNG API calls in a live mod.
  local spinning_wheels = self:detect_tire_spin_on_soft_surfaces()

  -- Step 2: If spin is detected, modify ground parameters accordingly.
  if #spinning_wheels > 0 then
    self:modify_ground_parameters_on_spin(spinning_wheels, dt)
  end

  -- Step 3: Always call recovery function to allow ground to revert to its original state over time.
  self:recover_ground_parameters(dt)

  -- Step 4: (IMPORTANT - CONCEPTUAL) Apply changes to BeamNG Engine.
  -- The parameters in `self.data.MUD` and `self.data.SAND` are now updated in Lua.
  -- To make these changes affect game physics, BeamNG-specific API calls are needed here.
  -- For example (fictional API calls):
  --   if engine.isGroundModelDynamic('MUD') then
  --     engine.updateDynamicGroundModelProperties('MUD', self.data.MUD)
  --   end
  --   if engine.isGroundModelDynamic('SAND') then
  --     engine.updateDynamicGroundModelProperties('SAND', self.data.SAND)
  --   end
  -- Consult BeamNG modding documentation for the correct API.
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
   - Common locations include:
     - `/mods/your_mod_name/lua/dynamic_ground.lua`
     - `/mods/your_mod_name/scripts/dynamic_ground.lua`
     - `/levels/your_level_name/scripts/dynamic_ground.lua` (for level-specific use)
   - The exact path might vary based on your mod's organization.

2. Script Loading:
   - This script needs to be loaded by BeamNG's Lua environment to be active.
   - Use the `require()` function in another Lua file that BeamNG executes. The path
     provided to `require()` should be relative to BeamNG's Lua root or known paths.
     For example, if placed in `/mods/your_mod_name/lua/dynamic_ground.lua`, you might
     load it as:

     ```lua
     -- In a level's main.lua, a vehicle's extension Lua, or a global gameplay script:
     local dynamicGroundSystem = require('your_mod_name/lua/dynamic_ground')
     -- Or, if the script is in a subfolder of the currently executing script's location:
     -- local dynamicGroundSystem = require('dynamic_ground') -- if in the same folder
     ```
   - Ensure this loading happens before you try to call its update function.

3. Calling the Update Function:
   - The core logic is triggered by calling the `update_dynamic_ground(dt)` function
     of the loaded module.
   - This function needs to be called repeatedly, ideally on every physics step.
   - The `dt` argument (delta time) is crucial for time-dependent calculations (like
     recovery rates and spin effect accumulation). BeamNG provides `dt` in its
     physics update callbacks.

     Conceptual example within a BeamNG callback:
     ```lua
     -- Assume 'dynamicGroundSystem' is already loaded as shown in step 2.

     -- Example: In a file that has an onPhysicsUpdate(dt) callback
     function onPhysicsUpdate(dt)
         -- Other update logic ...

         if dynamicGroundSystem then
             dynamicGroundSystem:update_dynamic_ground(dt)
         end

         -- Other update logic ...
     end
     ```

4. Engine Interaction (Conceptual - IMPORTANT):
   - This script, as provided, modifies Lua tables (`M.data.MUD`, `M.data.SAND`) that
     *represent* ground model parameters.
   - To make these changes affect the actual in-game physics, you MUST use BeamNG's
     specific Lua API functions to update the engine's ground models.
   - This script DOES NOT directly interface with the physics engine's ground models.
     That part is engine-specific and requires knowledge of BeamNG's modding API.
   - You would need to:
     a. Identify the relevant BeamNG API functions (e.g., for updating groundModel properties,
        potentially for specific areas or related to vehicle interactions).
     b. After calling `dynamicGroundSystem:update_dynamic_ground(dt)`, read the values
        from `dynamicGroundSystem.data.MUD` and `dynamicGroundSystem.data.SAND`.
     c. Use the BeamNG API functions to apply these values to the game engine.
        (e.g., `engine.setGroundModelProperty('MUD', 'defaultDepth', dynamicGroundSystem.data.MUD.defaultDepth)`)
        The actual API calls will likely be different; consult BeamNG documentation.

5. Accessing Modified Data:
   - You can access the current dynamically adjusted parameters from outside this script
     if needed (e.g., for UI display, other game logic).
     ```lua
     -- local dynamicGroundSystem = require('your_mod_name/lua/dynamic_ground')
     -- local currentMudParams = dynamicGroundSystem.data.MUD
     -- local currentSandParams = dynamicGroundSystem.data.SAND
     -- print("Current MUD default depth: " .. currentMudParams.defaultDepth)
     ```

6. Debugging:
   - Use BeamNG's in-game Lua console (often opened with `~` key) to execute snippets,
     print values from `dynamicGroundSystem.data`, and check for errors.
   - Add `print()` statements within this script's functions (especially in
     `update_dynamic_ground` or `modify_ground_parameters_on_spin`) to log values
     and trace execution. These logs usually appear in the console or log files.
     For example:
     `print("MUD shearStrength updated to: " .. M.data.MUD.shearStrength)`

Remember to consult the official BeamNG modding documentation and community resources
for the most accurate and up-to-date information on Lua scripting and ground model
manipulation within the engine.
------------------------------------------------------------------------------------------
]]
