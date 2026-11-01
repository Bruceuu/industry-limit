-- Shared helpers(game script and GUI both require this file).
local il = {}
il.id = "industry_limit"
il.script = il.id .. "::/industry_limit.gs"
il.setBlockedEvent = "IndustryLimitSetBlocked"
il.setLimitEvent = "IndustryLimitSetLimit"
il.deleteEvent = "IndustryLimitDelete"
il.clearBlockedEvent = "IndustryLimitClearBlocked"
il.connectEvent = "IndustryLimitConnect"

-- Active economy description (or nil).
function il.economy()
    local id = api.res.economyRep.find(api.res.getBaseConfig().economyId)
    if id < 0 then return nil end
    return api.res.economyRep.get(id), id
end

-- Money formatting via the game's own formatter when available.
function il.formatMoney(amount)
    local ok, text = pcall(api.util.formatMoney, math.floor(amount))
    if ok and type(text) == "string" then return text end
    return tostring(math.floor(amount))
end

local typeCache = nil
local spawnCache = nil
local spawnCacheEconomy = nil

-- Saved game-script state (blocked = { [placementTag] = boolean }). Safe to call from GUI.
function il.readState()
    if not api or not api.engine then return {} end
    local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(il.script)
    if not entity or entity < 0 then return {} end
    local component = api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT)
    return component and component.state or {}
end

-- placementTag and description name key for a construction entity.
function il.typeOfConstruction(constructionEntity)
    local construction = api.engine.getComponent(constructionEntity, api.type.ComponentType.CONSTRUCTION)
    if not construction then return nil end
    local id = api.res.constructionRep.find(construction.fileName)
    if id < 0 then return nil end
    local desc = api.res.constructionRep.get(id)
    local tag = desc.placementTag
    if type(tag) ~= "string" or tag == "" then return nil end
    return tag, desc.description and desc.description.name or nil
end

-- PLAYER_OWNED may sit on the industry or on its construction entity.
function il.isPlayerOwned(industryEntity, industry)
    local T = api.type.ComponentType
    return api.engine.getComponent(industryEntity, T.PLAYER_OWNED) ~= nil
        or (industry and industry.construction and api.engine.getComponent(industry.construction, T.PLAYER_OWNED) ~= nil)
        or false
end

-- Resolve a window/entity id to an industry description. entityId may be the industry
-- entity or its construction entity.
function il.describeIndustry(entityId)
    local T = api.type.ComponentType
    if not api.engine.entityExists(entityId) then return { industry = false } end
    local industryEntity = entityId
    local industry = api.engine.getComponent(entityId, T.INDUSTRY)
    if not industry then
        local construction = api.engine.getComponent(entityId, T.CONSTRUCTION)
        if construction and construction.industries and #construction.industries > 0 then
            industryEntity = construction.industries[1]
            industry = api.engine.getComponent(industryEntity, T.INDUSTRY)
        end
    end
    if not industry then return { industry = false } end
    local tag, name = il.typeOfConstruction(industry.construction)
    return {
        industry = true, entity = industryEntity, tag = tag, name = name,
        playerOwned = il.isPlayerOwned(industryEntity, industry),
    }
end

function il.prettify(tag)
    return (tostring(tag):gsub("_", " "):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- Display name: localised description name when it resolves, else a prettified tag.
function il.displayName(tag, nameKey)
    -- description.name is already translated by the .con.lua (_("INDUSTRIES_..._NAME")).
    if type(nameKey) == "string" and nameKey ~= "" then return nameKey end
    return il.prettify(tag)
end

-- Icon of an industry construction. description.icon is normally a full path; if it is a bare file
-- name, derive it from the resource name (::/industries/<tag>/<tag>.con -> .tga). "@2x" is resolved by the game.
local function iconFor(desc, resName)
    local icon = desc.description and desc.description.icon
    if type(icon) == "string" and icon ~= "" and icon:find("/", 1, true) then return icon end
    local path = tostring(resName):gsub("%.con$", ".tga")
    if not path:find("::", 1, true) then path = "::/" .. path:gsub("^/", "") end
    return path
end

-- Icons of the first `max` cargos an industry produces, read from its construction's stock list
-- (updateScript.params.stockListConfig.stocks with type OUTPUT_STOCK, as base mod.script.tl reads it).
local function outputIcons(desc, max)
    local icons = {}
    pcall(function()
        local cfg = desc.updateScript and desc.updateScript.params and desc.updateScript.params.stockListConfig
        if not cfg then return end
        for _, stock in ipairs(cfg.stocks) do
            if stock.type == "OUTPUT_STOCK" and #icons < (max or 3) then
                local id = api.res.cargoTypeRep.find(stock.cargoType)
                local cargo = id and id >= 0 and api.res.cargoTypeRep.get(id) or nil
                if cargo and type(cargo.icon) == "string" and cargo.icon ~= "" then icons[#icons + 1] = cargo.icon end
            end
        end
    end)
    return icons
end

-- "in about N days" / "in about N months" from a game-time duration (ms, default calendar).
function il.formatDuration(ms)
    local dayMs = api.util.getDefaultYearDuration() / 365.25
    local days = math.max(0, math.floor(ms / dayMs + 0.5))
    if days == 1 then return _("1 day") end
    if days < 60 then return string.format(_("%d days"), days) end
    return string.format(_("%d months"), math.floor(days / 30.44 + 0.5))
end

-- All industry types present in the loaded resources, sorted by display name.
function il.listTypes()
    if typeCache then return typeCache end
    local byTag, list = {}, {}
    for id, resName in pairs(api.res.constructionRep.getAll()) do
        local desc = api.res.constructionRep.get(id)
        local tag = desc and desc.placementTag
        if type(tag) == "string" and tag ~= "" and not byTag[tag]
            and (desc.isIndustry or tostring(resName):find("/industries/", 1, true)) then
            local entry = { tag = tag, name = il.displayName(tag, desc.description and desc.description.name),
                            icon = iconFor(desc, resName), outputs = outputIcons(desc, 3) }
            byTag[tag] = entry
            list[#list + 1] = entry
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    typeCache = list
    return list
end

-- Industry types the active economy can spawn (economy.placementParams), sorted by buildOrder.
-- start = no prerequisite industries (primary producers); others appear as demand grows.
function il.listSpawnable()
    local baseConfig = api.res.getBaseConfig()
    local economyId = api.res.economyRep.find(baseConfig.economyId)
    if economyId < 0 then return {} end
    if spawnCache and spawnCacheEconomy == economyId then return spawnCache end
    local economy = api.res.economyRep.get(economyId)
    local names = {}
    local icons, outputs = {}, {}
    for _, entry in ipairs(il.listTypes()) do
        names[entry.tag] = entry.name; icons[entry.tag] = entry.icon; outputs[entry.tag] = entry.outputs
    end
    local list = {}
    for tag, params in pairs(economy.placementParams) do
        list[#list + 1] = {
            tag = tag, name = names[tag] or il.prettify(tag), icon = icons[tag], outputs = outputs[tag] or {}, tier = params.tier or 0,
            order = params.buildOrder or 0
        }
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.tag < b.tag
    end)
    spawnCache = list
    spawnCacheEconomy = economyId
    return list
end

return il
