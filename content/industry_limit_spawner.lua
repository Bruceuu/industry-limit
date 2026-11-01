-- custom spawner
-- With the custom spawner on,
-- mod.script.lua's preRunFn switches the engine spawner off (baseConfig...spawnIndustries = false).
-- The game embeds Lua 5.2: no integer division, no bit operators.
local il = ug_require "industry_limit::/industry_limit.lua"

local sp = {}

-- Tunables (years are game years, api.util.getDefaultYearDuration()).
local MIN_FACTOR, MEAN_EXTRA, MAX_FACTOR = 0.4, 0.6, 3.0   -- spawn interval: 0.4 + Exp(0.6), capped at 3 years
local RETRY_NO_DEMAND, RETRY_FAIL = 0.1, 0.05              -- years until the next attempt
local MAX_TRIES = 3                                         -- type candidates tried per attempt
local BANK_CHECK_P = 0.0009
local MIN_WARN_SPACING_YEARS = 0.25
local KEEP_FRACTION = 0.6
local MIN_KEEP = 2                                          -- never fewer than the last 2 of a type
local REMOVE_RETRY_YEARS = 0.02                             -- wait before re-sending a removal that did not happen
local MIN_UTILISATION = 0.5                                 -- existing instances must ship >= 50% of output
local PRESSURE_MIN = 0.8

local function yearMs() return api.util.getDefaultYearDuration() end

local function log(msg) debugPrint("[industry_limit] " .. tostring(msg)) end
local function R(kind, fields) log(kind, fields) end

local function seed(gt, salt) math.randomseed(gt.gameTime * 7 + gt.updateCount + (salt or 0)) end

local function drawInterval(gt)
    seed(gt, 1)
    local u = math.random()
    return math.floor(yearMs() * math.min(MAX_FACTOR, MIN_FACTOR + (-math.log(1 - u)) * MEAN_EXTRA))
end

local function spState(s)
    if type(s.sp) ~= "table" then s.sp = {} end
    if type(s.ours) ~= "table" then s.ours = {} end
    return s.sp
end

-- Called every scan from the game script's update. Returns true when an attempt is due.
function sp.schedule(state, gt)
    local s = state:get()
    local p = spState(s)
    if not p.nextT then
        p.nextT = gt.gameTime + drawInterval(gt)
        state:set(s)
        R("spawner-scheduled", { nextT = p.nextT })
        return false
    end
    return gt.gameTime >= p.nextT
end

local function cargoShort(id)
    local ok, name = pcall(api.res.cargoTypeRep.getName, id)
    if not ok then return tostring(id) end
    return (tostring(name):gsub("^::/cargos/[^/]+/", ""):gsub("%.cargo$", ""))
end

-- Counts per type, utilisation of mature instances, summed town cargo needs, town entities.
local function gather(now)
    local T = api.type.ComponentType
    local counts, needs, towns = {}, {}, {}
    api.engine.forEachEntityWithComponent(function(e)
        local ind = api.engine.getComponent(e, T.INDUSTRY)
        if not ind then return end
        local tag = il.typeOfConstruction(ind.construction)
        if not tag then return end
        counts[tag] = (counts[tag] or 0) + 1
    end, T.INDUSTRY)
    api.engine.forEachEntityWithComponent(function(e)
        local town = api.engine.getComponent(e, T.TOWN)
        if not town or not town.cargoNeeds then return end
        towns[#towns + 1] = e
        for _, cargoTypes in ipairs(town.cargoNeeds) do
            for _, pair in ipairs(cargoTypes) do
                local cargoName = cargoShort(pair[1])
				needs[cargoName] = true
            end
        end
    end, T.TOWN)
    return counts, needs, towns
end

-- Candidate list where there is clear, unmet demand
local function candidates(s, counts, needs)
    local ecoId = api.res.economyRep.find(api.res.getBaseConfig().economyId)
    if ecoId < 0 then return {} end
    local eco = api.res.economyRep.get(ecoId)
	local okDeps, deps = pcall(api.engine.util.industry.getEconomyCargoDependencies, ecoId)
    if not okDeps or not deps then return {} end
	local need = {}
	for cargo in pairs(needs or {}) do
        for tag in pairs(deps[cargo] or {}) do 
			need[tag] = true 
			
			-- Compatibility because the game does not return all industries if multiple are eligible for a single cargo
			if tag == "oil_platform" then
				need["oil_well"] = true
			elseif tag == "sand_excavator" then
				need["sand_pit"] = true
			end
			
		end
    end

    local list = {}
    for tag in pairs(eco.placementParams) do
		local haveNeed = need[tag] or false
        local have = counts[tag] or 0
        local blocked = s.blocked and s.blocked[tag] 
		local limit = s.limit[tag] or "unlimited"
        if not blocked and haveNeed and (limit == "unlimited" or (limit ~= "unlimited" and have < limit)) then
            list[#list + 1] = tag
        end
    end
    return list
end

-- random pick
local function pickRandom(list)
    if #list == 0 then return nil end
    return table.remove(list, math.random(#list))
end

local function notifyFounded(industryEntity)
    pcall(function()
        local r = api.engine.getRevision(industryEntity)
        api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", "Notifications", "add", {
            type = "::/game_mechanics/notifications/types/industry_spawn.script",
            params = { entity = { entity = industryEntity, revision = { num = { r.num[1], r.num[2], r.num[3] } } } },
            autoDismissDuration = 60000,
        }))
    end)
end

-- Road connection. A script spawn only gets the industry's own entrance stub (log + user evidence
-- 2026-10-11); the engine connects its own spawns in a separate C++ step. The only engine-quality road
-- builder reachable from Lua is the map editor's "connect towns with industries" command. keep=true keeps
-- all existing streets (keep=false would remove them - never used). It acts on all industries; effect on
-- already-connected industries is UNVERIFIED in-game, hence the "il.connect" option and logging.
function sp.connectEnabled()
    local ok, all = pcall(api.engine.config.getModParams)
    local mine = ok and all and all[il.id]
    local v = mine and tonumber(mine["il.connect"])
    return v == nil or v == 2      -- default: on
end

-- Must be called where command callbacks are allowed (postUpdate, handleEvent). Records the outcome in
-- state.lastConnect so the industry window can show feedback (the generator takes a few seconds).
function sp.connect(state, industryEntity, reason)
    local ok, result = false, "error"
    local okRun, err = pcall(function()
        local ind = api.engine.getComponent(industryEntity, api.type.ComponentType.INDUSTRY)
        if not ind then result = "no-industry"; return end
        local town = api.engine.system.streetConnectorSystem.getConstructionClosestTown(ind.construction)
        if not town or town < 0 then
            result = "no-town"
            log("road connect: no town found for industry " .. tostring(industryEntity))
            return
        end
        api.cmd.sendCommand(api.cmd.makeTownConnectWithIndustriesCmd({ town }, {}, true),
            function(_, success)
                ok = success == true
                result = ok and "built" or "failed"
                log("road connect for industry " .. tostring(industryEntity) .. " via town " .. tostring(town) .. ": " .. tostring(success))
                R("road-connect", { industry = industryEntity, town = town, success = ok, reason = reason })
            end)
    end)
    if not okRun then log("road connect error: " .. tostring(err)) end
    pcall(function()
        local s = state:get()
        local seq = (s.lastConnect and s.lastConnect.seq or 0) + 1
        s.lastConnect = { entity = industryEntity, ok = ok, result = result, seq = seq, reason = reason }
        state:set(s)
    end)
end

-- Called by the scan with the industries it just detected: founding notification + road connection.
-- Picks the new industry of the type we just built (pending value = tag), else the first new one.
local function matching(newOnes, tag)
    for _, n in ipairs(newOnes) do if n.tag == tag then return n end end
    return newOnes[1]
end

function sp.notifyDetected(s, newOnes)
    if type(s.sp) ~= "table" or not newOnes[1] then return end
    if s.sp.pendingNotify then
        notifyFounded(matching(newOnes, s.sp.pendingNotify).entity)
        s.sp.pendingNotify = nil
    end
    if s.sp.pendingConnect then
        local n = matching(newOnes, s.sp.pendingConnect)
        s.sp.pendingConnect = nil
        if sp.connectEnabled() then return n.entity end   -- connected in postUpdate
    end
end

local function industryEntityOf(entity)
    local T = api.type.ComponentType
    local con = api.engine.getComponent(entity, T.CONSTRUCTION)
    if con and con.industries and con.industries[1] then return con.industries[1] end
    if api.engine.getComponent(entity, T.INDUSTRY) then return entity end
end

-- Tries to build one industry of `tag`; returns true on success. Sends the founding notification
-- (directly if the result entity resolves, otherwise when the scan detects the new industry).
local function tryBuild(p, now, tag, town, attempt, counts)
    local okP, proposal = pcall(api.engine.util.proposal.makeIndustrySpawnProposal, tag, town)
    if not (okP and proposal) then
        R("spawner-attempt", { result = "no-proposal", tag = tag, try = attempt, error = okP and "nil" or tostring(proposal) })
        return false
    end
    local succeeded = false
    -- Commands and their callbacks run immediately on the engine state (cmd.d.tl), as vanilla relies on.
    api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, false),
        function(_, success, resultEntities)
            local ent = success and resultEntities and resultEntities[1] and resultEntities[1][1] or nil
            local ind = ent and industryEntityOf(ent) or nil
            R("spawner-result", { tag = tag, success = success == true, entity = ent, industry = ind })
            log("custom spawn " .. tag .. (success and " ok" or " failed"))
            if success then
                succeeded = true
                p.pendingNotify = tag
                p.pendingConnect = tag
                if ind then notifyFounded(ind); p.pendingNotify = nil end
            end
        end)
    R("spawner-attempt", { result = succeeded and "built" or "build-failed", tag = tag, town = town, try = attempt, counts = counts })
    return succeeded
end

-- Runs from postUpdate.
function sp.attempt(state, gt)
    local s = state:get()
    local p = spState(s)
    local now = gt.gameTime
    local Y = yearMs()
    -- Advance the timer first so that an exception below cannot cause a retry storm.
    p.fails = p.fails or 0
    p.nextT = now + math.floor(RETRY_FAIL * Y * math.min(8, 2 ^ p.fails))
    state:set(s)

    local counts, needs, towns = gather(now)
    seed(gt, 2)

    local list = candidates(s, counts, needs)
    if #list == 0 then
        p.nextT = now + math.floor(RETRY_NO_DEMAND * Y)
        state:set(s)
        R("spawner-attempt", { result = "no-demand", counts = counts })
        return
    end
    local succeeded = false
    for attempt = 1, math.min(MAX_TRIES, #list) do
        local c = pickRandom(list)
        local town = nil
        if #towns > 0 then town = towns[math.random(#towns)] end
        if tryBuild(p, now, c, town, attempt, counts) then
            succeeded = true
            break
        end
    end
    if succeeded then
        p.fails = 0
        p.nextT = now + drawInterval(gt)
        p.lastT = now
    else
        p.fails = math.min(p.fails + 1, 3)
        p.nextT = now + math.floor(RETRY_FAIL * Y * math.min(8, 2 ^ p.fails))
    end
    state:set(s)
end

local function lastLog(stockList, logName)
    local logBook = api.engine.getComponent(stockList, api.type.ComponentType.LOG_BOOK)
    if not logBook then return nil end
    local entry = logBook.name2log_native:find(logName)
    if entry == nil then return nil end
    local num = entry.times_native:size()
    if num == 0 then return nil end
    return entry.times_native:at(num)
end

-- Spawner switched off: forget the schedule so the menu does not show a stale countdown.
function sp.clearSchedule(state)
    local s = state:get()
    if type(s.sp) == "table" and s.sp.nextT then
        s.sp.nextT = nil
        state:set(s)
    end
end

-- Journal entries like vanilla's industry_closed_<tag>.
function sp.journal(tags)
    pcall(function()
        local counts, list = {}, {}
        for _, tag in ipairs(tags) do counts[tag] = (counts[tag] or 0) + 1 end
        for tag, n in pairs(counts) do list[#list + 1] = { "industry_closed_" .. tag, n, true } end
        if #list > 0 then
            api.cmd.sendCommand(api.cmd.makeJournalLogEntryCmd(api.engine.util.getWorld(), list))
        end
    end)
end

return sp
