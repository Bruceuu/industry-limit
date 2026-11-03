-- Industry window card (IndustryEowExtensionPoint plugin): bankruptcy status
-- Block/Allow this type, and Connect to the road network.
local translate = _
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local engineReact = ug_require "::/gui/main/engine_react_util.tl"
local cards = ug_require "::/gui/main/content_card.tl"
local industryEow = ug_require "::/gui/entity_window/industry/industry_eow.script.tl"
local il = ug_require "industry_limit::/industry_limit.lua"

local ICON = {
    locked = "::/gui/builtin/window/icons/lock.tga",
    unlocked = "::/gui/menu/icons/symbol_lock_unlocked.tga",
    road = "::/gui/entity_window/icons/building_industry.tga",
}

local function send(name, param)
    -- Commands must be created on the main thread, after parallel GUI work has joined.
    react.enqueueJoin(function()
        api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(il.script, il.id, name, param))
    end, "Industry limit event")
end

local function text(str, class) return builtin.TextView{ meta = { class = class or "font-scale-body" }, text = str } end
local function iconButton(path, label, opts)
    return builtin.Button{
        meta = { class = opts.class or "secondary", tooltip = opts.tooltip },
        content = builtin.BoxLayout{
            orientation = builtin.type.Orientation.Horizontal,
            children = {
                builtin.ImageView{ meta = { class = "il-btn-icon" }, path = path, scaling = builtin.type.ImageViewScaling.AutoFit },
                text(label),
            },
        },
        onClick = opts.onClick,
    }
end

local function sameInfo(a, b)
    if a == nil or b == nil then return a == b end
    return a.industry == b.industry and a.entity == b.entity and a.tag == b.tag and a.playerOwned == b.playerOwned
        and a.blocked == b.blocked and a.deadline == b.deadline and a.bucket == b.bucket and a.connectSeq == b.connectSeq
end

function data()
    local Controls = react.RegisterRecipe("IndustryLimitControls", function(params)
        local connectPending = react.useState(false)    -- false, or the lastConnect.seq seen when clicked
        local info = engineReact.useStepStateTimer(function()
            local d = il.describeIndustry(params.entityId)
            if d.industry then
                local st = il.readState()
                d.blocked = d.tag ~= nil and (st.blocked or {})[d.tag] == true
				d.limit = d.tag ~= nil and (st.limit[d.tag] or "unlimited") or nil
                local r = (st.ours or {})[tostring(d.entity)]
                d.deadline = r and not r.removing and r.deadline or nil
                local lc = st.lastConnect
                d.connectSeq = lc and lc.seq or 0
                d.connectEntity = lc and lc.entity
                d.connectResult = lc and lc.result
                local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
                d.now = gt and gt.gameTime or 0
                d.bucket = math.floor(d.now / (api.util.getDefaultYearDuration() / 73))
            end
            return d
        end, 0.5, sameInfo):old()
        -- Hooks must run in the same order on every render: declare before any early return.
        local shown = react.useRef(info and info.entity)
        if not info or not info.industry then return builtin.BoxLayout{} end

        local typeName = info.tag and il.displayName(info.tag, info.name) or "?"
        local children = {}
        if info.blocked then
            children[#children + 1] = text(string.format(translate("%s is blocked: no new ones are founded."), typeName), "font-scale-annotation, il-card-text")
        end
		if info.limit then
			children[#children + 1] = text(string.format(translate("%s has a limit of %s"), typeName, tostring(info.limit)), "font-scale-annotation, il-card-text")
		end
        local buttons = {}
        if info.tag then
            buttons[#buttons + 1] = iconButton(info.blocked and ICON.unlocked or ICON.locked,
                info.blocked and translate("Allow type") or translate("Block type"), {
                tooltip = info.blocked and string.format(translate("Allow new %s to be founded again."), typeName)
                    or string.format(translate("Stop new %s from being founded."), typeName),
                onClick = function() send(il.setBlockedEvent, { tag = info.tag, blocked = not info.blocked }) end,
            })
        end
        children[#children + 1] = builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = buttons }
        return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
    end)

    local Plugin = react.RegisterPluginRecipe(industryEow.IndustryEowExtensionPoint, "IndustryLimitPlugin", function(params)
        return builtin.BoxLayout{
            child = cards.ContentCard{
                meta = { localKey = "industryLimit" },
                title = translate("Industry limit"),
                initialCalloutTextPermanent = "",
                extraChildrenPermanent = { Controls{ entityId = params.entityId } },
                hasPermanentFocusables = true,
                gameCtx = params.gameCtx,
                showOnRightSide = params.showCalloutOnRightSide,
            },
        }
    end)

    return { IndustryLimitPlugin = Plugin }
end
