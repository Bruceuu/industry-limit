-- load-time hooks. Mod params (1-based index; 2 = on):
--   il.spawner    custom spawner: switches the engine's automatic industry spawner off.
local MOD_ID = "industry_limit"

local function enabled(allModParams, key)
    local mine = type(allModParams) == "table" and allModParams[MOD_ID]
    return type(mine) == "table" and tonumber(mine[key]) == 2
end

local function preRunFn(captureParams, configDict, allModParams, baseConfig)
    local dev = baseConfig and baseConfig.economy and baseConfig.economy.industryDevelopment
    if not dev then return end
    dev.spawnIndustries = false
    debugPrint("[industry_limit] engine industry spawner switched off (custom spawner on)")
end

function data()
    return { preRunFn = preRunFn }
end
