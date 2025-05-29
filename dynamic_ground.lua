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

It now attempts a more robust material identification by first trying to use
`editor_terrainEditor.getMaterialsInJson()` to dynamically fetch material names.
If this is unavailable or fails, it relies on user-configured fallback mappings.

IMPORTANT: This script modifies Lua tables that *represent* ground parameters.
Actual application of these parameters to the BeamNG physics engine requires
additional engine-specific Lua API calls, as detailed in the integration
instructions at the end of this file. The accuracy of MUD/SAND detection
heavily relies on the correct functioning or configuration of `M:getMaterialNameById()`.
--]]

-- Module table 'M' encapsulates all public state and functions.
local M = {
    materialNameCache = nil -- Initialize cache for material ID to name mapping. Populated on first use.
}

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
-- Translates a ground material ID to its internal name (e.g., "MUD", "SAND_BEACH").
--
-- Operation:
-- 1. Caching: On the first call, it attempts to populate `self.materialNameCache` by
--    querying `editor_terrainEditor.getMaterialsInJson()`. This API (if available)
--    provides a list of materials used in the current level, including their IDs
--    and internal names. The cache stores these mappings (ID as string key) to
--    avoid repeated API calls.
-- 2. Cache Lookup: Subsequent calls first try to find the material name in the cache.
-- 3. Fallback: If `editor_terrainEditor` or its function is unavailable (e.g., in some
--    gameplay contexts where editor scripts are not loaded), or if the cache population
--    fails, or if an ID is not found in the cache, the function resorts to a
--    hardcoded list of example material IDs.
--
-- **CRITICAL USER TASK - Fallback Configuration:**
-- The hardcoded fallback IDs (e.g., 0 for ASPHALT, "10" for MUD, "11" for SAND)
-- are **PLACEHOLDERS AND LIKELY INCORRECT** for any specific BeamNG level or setup.
-- If the primary method (using `editor_terrainEditor`) is not functional or
-- reliable in your target environment, **YOU MUST VERIFY AND UPDATE THESE FALLBACK IDs**
-- in the code below. Failure to do so will result in MUD and SAND not being
-- correctly identified, and thus, the dynamic effects will not apply.
-- Refer to the integration instructions at the end of this file for tips on finding IDs.
--
-- Log Messages:
-- - 'I' (Info): Successful caching of material names.
-- - 'W' (Warning): `editor_terrainEditor` API issues or empty results, indicating
--   reliance on fallbacks.
-- - 'D' (Debug, commented out): Can be enabled to log when fallback is used for a specific ID.
--
-- @param self (table) The module instance (M).
-- @param material_id (number) The physics material ID from `wheel_obj.contactMaterialID1`.
-- @return (string) The internal name of the material or a placeholder string
--                  (e.g., "UNKNOWN_MATERIAL_ID_xx") if not recognized.
---
function M:getMaterialNameById(material_id)
    if self.materialNameCache == nil then -- Only try to populate if nil (never tried before)
        self.materialNameCache = {} -- Initialize to empty table, marking that we've tried

        if editor_terrainEditor and editor_terrainEditor.getMaterialsInJson then
            -- Note: `updateMaterialLibrary` might be needed if materials change dynamically
            -- during editor use, but could be risky/slow in gameplay. Omitted for now.
            local materials_json = editor_terrainEditor.getMaterialsInJson()
            if materials_json then
                local count = 0
                for id_key, mtl_data in pairs(materials_json) do
                    if mtl_data and mtl_data.internalName then
                        self.materialNameCache[tostring(id_key)] = mtl_data.internalName
                        count = count + 1
                    end
                end
                if count > 0 then
                    log('I', 'DynamicGround', 'Successfully cached ' .. count .. ' terrain material names from editor_terrainEditor.')
                else
                    log('W', 'DynamicGround', 'editor_terrainEditor.getMaterialsInJson() returned no materials or unexpected structure. Cache empty, will use fallbacks.')
                end
            else
                log('W', 'DynamicGround', 'editor_terrainEditor.getMaterialsInJson() returned nil. Cannot cache from editor API, will use fallbacks.')
            end
        else
            log('W', 'DynamicGround', 'editor_terrainEditor or .getMaterialsInJson not available. Cannot cache from editor API, will use fallbacks.')
        end
    end

    local id_str = tostring(material_id)
    if self.materialNameCache[id_str] then -- Check populated cache (even if it's empty from a failed API call)
        return self.materialNameCache[id_str]
    end
    
    -- Fallback if not in cache or cache population failed.
    -- log('D', 'DynamicGround', 'Material ID ' .. id_str .. ' not in cache. Using hardcoded fallback.')

    -- !! USER ACTION REQUIRED FOR FALLBACKS !!
    -- The following IDs are EXAMPLES and VERY LIKELY INCORRECT for your specific map/setup.
    -- Update these if the editor_terrainEditor method is not working or not available.
    if material_id == 0 then return "ASPHALT"  -- Often ID 0, but verify.
    elseif id_str == "10" then return "MUD"   -- PURELY AN EXAMPLE ID
    elseif id_str == "11" then return "SAND"  -- PURELY AN EXAMPLE ID
    -- Add more verified fallback mappings here:
    -- elseif id_str == "your_mud_id_as_string" then return "MUD"
    -- elseif id_str == "your_sand_id_as_string" then return "SAND"
    end
    
    return "UNKNOWN_MATERIAL_ID_" .. id_str
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
-- It relies on `self:getMaterialNameById()` to identify relevant ground materials;
-- the accuracy of this function is critical.
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
    local spin_threshold = 5.0

    local veh = be:getPlayerVehicle(0)
    if not veh then return spinning_wheels end

    local vehicle_wheels = veh.wheels
    if not vehicle_wheels then return spinning_wheels end

    local vehicle_speed = electrics.values.wheelspeed or 0

    for i = 1, #vehicle_wheels do
        local wheel_obj = vehicle_wheels[i]
        if wheel_obj then
            if wheel_obj.isBroken then goto continue_wheel_loop end
            if wheel_obj.contactMaterialID1 and wheel_obj.contactMaterialID1 >= 0 and wheel_obj.contactDepth == 0 then
                -- Critical step: identify material name from its physics ID.
                -- Correctness of getMaterialNameById (either via editor API or user-set fallbacks) is key.
                local material_name = self:getMaterialNameById(wheel_obj.contactMaterialID1)

                if (material_name == "MUD" or material_name == "SAND") and self.data[material_name] then
                    if wheel_obj.isPropulsed then
                        local wheel_linear_velocity = (wheel_obj.angularVelocity or 0) * (wheel_obj.radius or 0.3)
                        local slip_amount = wheel_linear_velocity - vehicle_speed
                        if wheel_linear_velocity > vehicle_speed + spin_threshold then
                            table.insert(spinning_wheels, {
                                wheelID = wheel_obj.name,
                                materialType = material_name,
                                slipAmount = slip_amount
                            })
                        end
                    end
                end
            end
        end
        ::continue_wheel_loop::
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
  local spinning_wheels = self:detect_tire_spin_on_soft_surfaces()
  if #spinning_wheels > 0 then
    self:modify_ground_parameters_on_spin(spinning_wheels, dt)
  end
  self:recover_ground_parameters(dt)
  -- Step 4: (IMPORTANT - CONCEPTUAL) Apply changes to BeamNG Engine.
  -- Consult BeamNG modding documentation for the correct API.
end

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

4. CRITICAL USER TASK: Material Identification (`M:getMaterialNameById`):
   - The function `M:getMaterialNameById(material_id)` is crucial for identifying MUD and SAND.
   - **Primary Method (Editor API):** It first attempts to use `editor_terrainEditor.getMaterialsInJson()`
     to dynamically fetch all material names and cache them. This is the preferred method if it
     works in your execution context (e.g., if `editor_terrainEditor` is available).
     Check console logs for 'DynamicGround' messages about cache success or failure.
   - **Fallback Method (Manual Configuration):** If the editor API method fails (e.g.,
     `editor_terrainEditor` is not available during normal gameplay, or returns no data),
     the script will use hardcoded fallback example IDs within `M:getMaterialNameById`.
     **THESE FALLBACK IDs (e.g., 10 for MUD, 11 for SAND) ARE PLACEHOLDERS AND ARE
     VERY LIKELY INCORRECT FOR YOUR SPECIFIC MAP/SETUP.**
   - **Action Required:**
     1. Test if the editor API method successfully caches materials (see logs).
     2. If not, or to be safe, you **MUST** identify the correct physics material IDs
        (these are usually numbers, but the function converts them to strings for lookup)
        for MUD, SAND, ASPHALT, etc., on your target map(s).
     3. **Update the fallback `if/elseif` conditions in `M:getMaterialNameById`** with these
        correct, verified IDs.
   - **Finding Material IDs:**
     - Temporarily add `print(wheel_obj.name, wheel_obj.contactMaterialID1)` inside the wheel
       loop in `M:detect_tire_spin_on_soft_surfaces()` to see the raw ID when driving on known surfaces.
     - Consult BeamNG documentation, level data (e.g., terrain files), or ground model
       definition files (e.g., groundmodels.json, though these map names to properties, not IDs directly).
   - **Without correct material identification, dynamic effects will not apply to MUD/SAND.**

5. Dependencies & API Assumptions:
   - `be:getPlayerVehicle(0)`: To get the current player vehicle.
   - `veh.wheels`: A collection (likely array) of wheel objects/tables.
   - Wheel Properties: `name`, `contactMaterialID1`, `contactDepth`, `angularVelocity`,
     `radius`, `isBroken`, `isPropulsed`.
   - `electrics.values.wheelspeed`: For overall vehicle speed.
   - `editor_terrainEditor.getMaterialsInJson()`: Conditionally used for material name caching.
     If unavailable, the script relies on user-configured fallbacks in `M:getMaterialNameById`.
   - Exact property names/structures might vary with mods or BeamNG versions; adjust if needed.

6. Engine Interaction (Conceptual - IMPORTANT):
   - This script manages Lua tables (`M.data.MUD`, `M.data.SAND`). To affect in-game physics,
     you must use BeamNG-specific Lua APIs to apply these values to the engine's ground models.
     This "bridging" step is external to this script.

7. Accessing Modified Data:
   - Read current parameters from `dynamicGroundSystem.data.MUD` or `dynamicGroundSystem.data.SAND`.

8. Debugging:
   - Use `print()` or `log('D', 'DynamicGround', ...)` and BeamNG console.
   - Check console for 'DynamicGround' logs regarding material caching and fallbacks.

Remember to consult official BeamNG modding documentation and community resources.
------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------
-- Testing Strategy for dynamic_ground.lua
------------------------------------------------------------------------------------------

Once integrated and `M:getMaterialNameById()` is correctly implemented or verified, use these steps
to test the script's functionality within BeamNG:

1.  Prerequisites for Testing:
    *   **Script Loaded:** Confirm `dynamic_ground.lua` is loaded.
    *   **Update Function Called:** Ensure `M:update_dynamic_ground(dt)` is called every physics frame.
    *   **`getMaterialNameById` Configuration:** THIS IS THE MOST CRUCIAL STEP.
        *   If you expect `editor_terrainEditor.getMaterialsInJson()` to work (e.g., you are running
            in a context where editor APIs are available, like the World Editor):
            Check the game's console/log for a message like "Successfully cached ... terrain material names".
        *   If the editor API is not available or fails (check logs for warnings like
            "...editor_terrainEditor not available..." or "...getMaterialsInJson() returned nil..."),
            ensure you have **MANUALLY VERIFIED AND UPDATED THE FALLBACK EXAMPLE IDs** in the
            `M:getMaterialNameById()` function for MUD, SAND, and any other relevant materials
            for your specific map.
        *   Without correct material ID mapping (either dynamic or manual fallback), the script CANNOT
            identify MUD/SAND, and no dynamic effects will occur on these surfaces.

2.  Basic MUD/SAND Detection Test:
    *   **Check Logs First:** Review the game's console/log for messages from `DynamicGround`
        related to material caching (e.g., "Successfully cached terrain material names" or
        warnings if it failed). This indicates which lookup method `M:getMaterialNameById()` is using.
    *   **Add Temporary Logging (If Needed):**
        *   Inside `M:detect_tire_spin_on_soft_surfaces()`: When `material_name` is
            determined to be "MUD" or "SAND" (after the call to `self:getMaterialNameById`),
            log the `wheel_obj.name`, `material_name`, and `wheel_obj.contactMaterialID1`.
            Example: `log('D', 'DynamicGround', "Wheel " .. wheel_obj.name .. " on " .. material_name .. " (ID: " .. wheel_obj.contactMaterialID1 .. ")")`
        *   Inside `M:update_dynamic_ground()`: Log the `spinning_wheels` table if it's not empty.
            Example: `if #spinning_wheels > 0 then log('D', 'DynamicGround', "Spinning wheels: " .. serpent.block(spinning_wheels)) end`
            (Requires `serpent` or similar for easy table printing).
    *   **Test Drive:** Drive onto a known MUD surface, then a known SAND surface.
    *   **Verify Detection:** Check logs to confirm:
        *   The script correctly identifies when wheels are on MUD or SAND based on the names from `getMaterialNameById`.
        *   The `spinning_wheels` table populates when tires spin on these surfaces.

3.  Parameter Modification Test (`M.data` Inspection):
    *   **Lua Console:** Use `pp(require('path/to/dynamic_ground').data.MUD)` (adjust path as loaded).
    *   **Perform Test:** Drive onto MUD, spin tires for some seconds, then inspect `M.data.MUD`.
    *   **Expected Behavior:** `defaultDepth` increases; `shearStrength`, friction coefficients decrease,
        all within `parameter_limits`. Repeat for SAND and `M.data.SAND`.

4.  Parameter Recovery Test:
    *   **Modify Parameters:** As above.
    *   **Cease Spin:** Move vehicle off the dynamic surface or stop spinning tires.
    *   **Observe Recovery:** Periodically inspect `M.data.MUD` or `M.data.SAND` via console.
    *   **Expected Behavior:** Parameters gradually revert to original values.

5.  `collisionType` Immutability Check:
    *   When inspecting `M.data`, confirm `collisionType` string remains unchanged.

6.  Troubleshooting Tips:
    *   **MUD/SAND Not Detected:**
        *   This is the most common issue and usually relates to `M:getMaterialNameById()`.
        *   **Check Logs:** Look for 'DynamicGround' messages about caching success/failure.
        *   **Verify Fallbacks:** If caching failed or isn't used, TRIPLE-CHECK that your fallback
            IDs in `M:getMaterialNameById()` are correct for the map you are using.
        *   **Log Raw IDs:** Add a temporary `log('D', 'DynamicGround', "Raw Contact ID: " .. wheel_obj.contactMaterialID1)`
            in `M:detect_tire_spin_on_soft_surfaces` *before* calling `getMaterialNameById` to see
            the actual ID numbers the game is reporting for the surfaces. Use these to correct your fallbacks.
    *   **Parameters Not Changing:**
        *   Confirm `M:update_dynamic_ground(dt)` is called (e.g., with a log at its start).
        *   Log `slip_amount` in `M:modify_ground_parameters_on_spin`.
        *   The `spin_threshold` in `M:detect_tire_spin_on_soft_surfaces()` might be too high/low.
    *   **Parameters Change Too Quickly/Slowly:**
        *   Adjust `*_factor` values in `M:modify_ground_parameters_on_spin`.
        *   Adjust `recovery_rate_factor` in `M:recover_ground_parameters`.
    *   **Warnings about `editor_terrainEditor`:** These are normal if not running in an editor context.
        The script is designed to fall back. The key is to ensure the fallbacks are accurate.
------------------------------------------------------------------------------------------
]]
