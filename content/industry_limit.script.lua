-- game script: enforces the block list and handles delete requests.
local il = ug_require "industry_limit::/industry_limit.lua"

local SCAN_INTERVAL_TICKS = 200

local function log(msg)
    debugPrint("[industry_limit] " .. tostring(msg))
end

local function ensure(s)
    if type(s.blocked) ~= "table" then s.blocked = {} end
	if type(s.limit) ~= "table" then s.limit = {} end
    if type(s.known) ~= "table" then s.known = {} end
    return s
end

local function subscribe(state)
    state:subscribeToEvent(il.setBlockedEvent)
	state:subscribeToEvent(il.setLimitEvent)
    state:subscribeToEvent(il.deleteEvent)
    state:subscribeToEvent(il.clearBlockedEvent)
    state:subscribeToEvent(il.connectEvent)
end

-- Custom spawner is optional too (see industry_limit_spawner.lua).
local okSp, sp = pcall(ug_require, "industry_limit::/industry_limit_spawner.lua")
if not okSp then
    debugPrint("[industry_limit] spawner module unavailable: " .. tostring(sp))
    sp = nil
end

local SUB_VERSION = 1

local function update(_, state, dt)
    local cur = state:get()
    if not state:hasEventSubscriptions() then
        subscribe(state)
        cur.subVersion = SUB_VERSION
        state:set(cur)
    elseif cur.subVersion ~= SUB_VERSION then
        state:subscribeToNoEvents()
        subscribe(state)
        cur.subVersion = SUB_VERSION
        state:set(cur)
    end
    if dt <= 0 then return end
    local gameTime = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
    if not gameTime or gameTime.updateCount % SCAN_INTERVAL_TICKS ~= 0 then return end

    local s = ensure(state:get())
    local T = api.type.ComponentType
    local seen, toRemove, counts, newOnes = {}, {}, {}, {}
    api.engine.forEachEntityWithComponent(function(entity)
        local key = tostring(entity)
        seen[key] = true
        local industry = api.engine.getComponent(entity, T.INDUSTRY)
        if not industry then return end
        local tag = il.typeOfConstruction(industry.construction)
        if tag then counts[tag] = (counts[tag] or 0) + 1 end
        if s.known[key] or not s.seeded then return end
        newOnes[#newOnes + 1] = { entity = entity, industry = industry, tag = tag }
        -- A new industry: remove it if its type is blocked (player-owned ones are left alone).
        if il.isPlayerOwned(entity, industry) then return end
        if tag and s.blocked[tag] then
            toRemove[#toRemove + 1] = entity
            log("blocked type '" .. tag .. "' spawned (entity " .. key .. "), removing")
        end
    end, T.INDUSTRY)
    -- Only write the state when the industry set or counts changed.
    local function sameKeys(a, b)
        for k, v in pairs(a) do if b[k] ~= v then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    -- Commands with callbacks are not allowed in update ("Callbacks are currently disallowed", log
    -- 2026-10-12), so the road connection for a new custom-spawned industry runs in postUpdate.
    local connectEntity = nil
    if sp and s.seeded and #newOnes > 0 then
        local okN, e = pcall(sp.notifyDetected, s, newOnes)
        if okN then connectEntity = e end
    end
    if s.seeded and #newOnes > 0 then
        -- Observed: the engine founds one industry every half game year (17 samples, 730000 ms).
        s.lastSpawnT = gameTime.gameTime
        s.lastSpawnTag = newOnes[#newOnes].tag
    end
    if not s.seeded or not sameKeys(seen, s.known) or not sameKeys(counts, s.counts or {})
        or (s.lastSpawnT and s.lastSpawnT == gameTime.gameTime) then
        s.known = seen
        s.counts = counts
        s.seeded = true
        state:set(s)
    end
    local result = nil
    if #toRemove > 0 then result = { industriesToRemove = toRemove } end
    if connectEntity then
        result = result or {}
        result.connectEntity = connectEntity
    end
    -- Optional custom spawner / bankruptcy (mod params, off by default). Errors here must not
    -- break blocking/deleting, hence pcall.
    if sp then
        local okOpt, spawnerOn = pcall(sp.params)
        if okOpt then
            local okRun, err = pcall(function()
                if spawnerOn then
                    if sp.schedule(state, gameTime) then
                        result = result or {}
                        result.spawnDue = true
                    end
                else
                    sp.clearSchedule(state)
                end
            end)
            if not okRun then log("custom spawner error: " .. tostring(err)) end
        end
    end
    return result
end

local function postUpdate(_, state, _, result)
    if type(result) ~= "table" then return end
    if result.industriesToRemove and #result.industriesToRemove > 0 then
        il.removeIndustries(result.industriesToRemove, function(success)
            if not success then log("removal of industries failed (will be retried for bankrupt ones)") end
        end)
    end
    if result.journalTags and #result.journalTags > 0 and sp then sp.journal(result.journalTags) end
    if result.connectEntity and sp then sp.connect(state, result.connectEntity, "custom-spawn") end
    if result.spawnDue and sp then
        local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
        local ok, err = pcall(sp.attempt, state, gt)
        if not ok then log("custom spawner attempt error: " .. tostring(err)) end
    end
end

local function handleEvent(_, state, _, id, name, param)
	log("got event" .. name)
	debugPrint(param)
    if id ~= il.id then
        if rec then rec.event(id, name, param) end
        return
    end
    local s = ensure(state:get())
    if name == il.clearBlockedEvent then
        s.blocked = {}
        state:set(s)
        log("cleared block list")
        return
    end
    if type(param) ~= "table" then return end
    if name == il.connectEvent then
        if sp and type(param.entity) == "number" then sp.connect(state, param.entity, "player") end
        return
    end
	if name == il.setLimitEvent then
		if type(param.tag) == "string" then
            s.limit[param.tag] = param.limit
            state:set(s)
            log((param.limit and "limit ") .. param.tag)
        end
    elseif name == il.setBlockedEvent then
        if type(param.tag) == "string" then
            s.blocked[param.tag] = param.blocked == true
            state:set(s)
            log((param.blocked and "blocking " or "allowing ") .. param.tag)
        end
    elseif name == il.deleteEvent then
        local entity = param.entity
        if type(entity) == "number" and api.engine.getComponent(entity, api.type.ComponentType.INDUSTRY) then
            log("deleting industry " .. tostring(entity))
            il.removeIndustries({ entity }, function(success)
                if not success then log("deletion failed for " .. tostring(entity)) end
            end)
        end
    end
end

function data()
    return { update = update, postUpdate = postUpdate, handleEvent = handleEvent }
end
