-- toolbar button (MainModButtonAreaExtension) + window listing every industry type
-- the active economy can found, with its count, block toggle. Rows are hand-built (no DataTable: unproven in mod windows).
local translate = _
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local engineReact = ug_require "::/gui/main/engine_react_util.tl"
local modArea = ug_require "::/gui/main/main_mod_button_area.tl"
local globals = ug_require "::/gui/main/game_react_globals.tl"
local il = ug_require "industry_limit::/industry_limit.lua"

local ICON = {
    toolbar = "::/gui/game_bar/icons/building_industry_gear_30.tga",
    locked = "::/gui/builtin/window/icons/lock.tga",
    unlocked = "::/gui/menu/icons/symbol_lock_unlocked.tga",
    money = "::/game_mechanics/finance/icons/symbol_coin_stack.tga",
}

local windowIsOpen = false
local windowApiInUse = nil
local notifyWindowGone = nil

local function send(name, param)
    -- Commands must be created on the main thread, after parallel GUI work has joined.
    react.enqueueJoin(function()
        api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(il.script, il.id, name, param or {}))
    end, "Industry limit event")
end

local function text(str, class) return builtin.TextView{ meta = { class = class or "font-scale-body" }, text = str } end
local function icon(path, class)
    return builtin.ImageView{ meta = { class = class or "il-btn-icon" }, path = path, scaling = builtin.type.ImageViewScaling.AutoFit }
end
local function comboBox(defaultValue, items, onValueChange)
    local mapped = {}
    for i, item in ipairs(items) do
        mapped[i] = builtin.ComboBoxItem{value = item, content = text(item, "font-scale-body")}
    end
    return builtin.ComboBox{ value = defaultValue, items = mapped, onValueChange = onValueChange }
end
local function iconButton(path, label, opts)
    return builtin.Button{
        meta = { class = opts.class or "secondary", enabled = opts.enabled ~= false, tooltip = opts.tooltip },
        content = builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = { icon(path), text(label) } },
        onClick = opts.onClick,
    }
end

-- Redraw signature: changes whenever anything shown in the window changes (polled every 0.5 s).
local function signature()
    local st = il.readState()
    local parts = {}
    local keys = {}
    for tag, flag in pairs(st.blocked or {}) do if flag then keys[#keys + 1] = "b:" .. tag end end
	for tag, limit in pairs(st.limit or {}) do if flag then keys[#keys + 1] = "l:" .. limit end end
    for tag, n in pairs(st.counts or {}) do keys[#keys + 1] = tag .. "=" .. tostring(n) end
    for key in pairs(st.ours or {}) do keys[#keys + 1] = "o:" .. key end
    table.sort(keys)
    parts[#parts + 1] = table.concat(keys, ",")
    parts[#parts + 1] = tostring(st.sp and st.sp.nextT) .. "|" .. tostring(st.lastSpawnT)
    -- Coarse time bucket (~5 game days) so countdowns refresh.
    local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
    parts[#parts + 1] = tostring(gt and math.floor(gt.gameTime / (api.util.getDefaultYearDuration() / 73)) or 0)
    return table.concat(parts, "|")
end

local function statusLines(st, names)
    local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
    local now = gt and gt.gameTime or 0
    local lines = {}
	local nextT = st.sp and st.sp.nextT
	if nextT and nextT > now then
		lines[#lines + 1] = text(string.format(translate("New industries: custom spawner. Next attempt in %s."), il.formatDuration(nextT - now)), "font-scale-body, il-wrap")
	else
		lines[#lines + 1] = text(translate("New industries: custom spawner. The next attempt is due."), "font-scale-body, il-wrap")
	end
    return lines
end

local FILTERS = { { "all", "All" }, { "built", "Built" }, { "missing", "Not built" }, { "blocked", "Blocked" } }

-- Fixed-width table cell. Widths come from CSS classes on a Component (BoxLayout ignores min/max size),
-- the same pattern the Auto Color Lines mod uses for its aligned table.
local function cell(class, child)
    return builtin.Component{
        meta = { class = "il-cell, " .. class },
        layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = { child } },
    }
end

local function row(cells)
    return builtin.BoxLayout{ meta = { class = "il-row" }, orientation = builtin.type.Orientation.Horizontal, children = cells }
end

local function nameCell(entry, extra, extraClass)
    local detail = string.format(translate("Tier %d"), entry.tier)
    return cell("il-col-name", builtin.BoxLayout{
        orientation = builtin.type.Orientation.Vertical,
        children = {
            text(entry.name .. (extra or ""), extraClass or "font-scale-body"),
            text(detail, "font-scale-annotation, il-wrap-col"),
        },
    })
end

-- Icons of the (up to 3) cargos the industry produces; the industry's own picture if it has none.
local function iconCell(entry)
    local icons = {}
    for _, path in ipairs(entry.outputs or {}) do
        icons[#icons + 1] = builtin.ImageView{ meta = { class = "il-cargo-icon" }, path = path, scaling = builtin.type.ImageViewScaling.AutoFit }
    end
    if #icons == 0 then
        icons[1] = builtin.ImageView{
            meta = { class = "il-type-icon" },
            path = entry.icon or "::/gui/entity_window/icons/building_industry.tga",
            scaling = builtin.type.ImageViewScaling.AutoFit,
        }
    end
    return cell("il-col-icon", builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = icons })
end

local comboBoxOptions = {0,1,2,3,4,5,6,7, "unlimited"}

local function industryRow(entry, st, count)
    local blocked = (st.blocked or {})[entry.tag] == true
	local limit = (st.limit and st.limit[entry.tag]) or "unlimited"
    return row({
        iconCell(entry),
        nameCell(entry),
        cell("il-col-count", text(tostring(count), "font-scale-body")),
		cell("il-col-limit", comboBox(limit, comboBoxOptions, function(val) send(il.setLimitEvent, { tag = entry.tag, limit = val}) end)),
        cell("il-col-block", iconButton(blocked and ICON.locked or ICON.unlocked, blocked and translate("Blocked") or translate("Allowed"), {
            class = blocked and "primary" or "secondary",
            tooltip = blocked and translate("Blocked: this type is never founded. Click to allow it again.")
                or translate("Click to stop this type from being founded."),
            onClick = function() send(il.setBlockedEvent, { tag = entry.tag, blocked = not blocked }) end,
        })),
    })
end

local function segmented(options, current, onPick)
    local buttons = {}
    for _, o in ipairs(options) do
        buttons[#buttons + 1] = builtin.Button{
            meta = { class = current == o[1] and "primary" or "secondary" },
            content = text(translate(o[2])),
            onClick = function() onPick(o[1]) end,
        }
    end
    return builtin.BoxLayout{ meta = { class = "il-row" }, orientation = builtin.type.Orientation.Horizontal, children = buttons }
end

local function scroll(rows)
    return builtin.ScrollArea{
        meta = { class = "il-scroll" },
        horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
        verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
        -- ScrollArea does not accept a Layout directly; wrap it in a Component (log evidence).
        content = builtin.Component{ layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = rows } },
    }
end

function data()
    local Content = react.RegisterRecipe("IndustryLimitMenuContent", function()
        local filter = react.useState("all")
        react.onUnmount(function()
            windowIsOpen = false
            windowApiInUse = nil
            if notifyWindowGone then notifyWindowGone() end
        end)
        engineReact.useStepStateTimer(signature, 0.5):old()
        local st = il.readState()
        local counts = st.counts or {}
        local list = il.listSpawnable()
        local names = {}
        for _, e in ipairs(list) do names[e.tag] = e.name end

        local children = statusLines(st, names)
		children[#children + 1] = segmented(FILTERS, filter:old(), function(v) filter:set(v) end)
		local rows, anyBlocked = {}, false
		for _, entry in ipairs(list) do
			local count = counts[entry.tag] or 0
			local blocked = (st.blocked or {})[entry.tag] == true
			if blocked then anyBlocked = true end
			local f = filter:old()
			if f == "all" or (f == "built" and count > 0) or (f == "missing" and count == 0) or (f == "blocked" and blocked) then
				rows[#rows + 1] = industryRow(entry, st, count)
			end
		end
		if #rows == 0 then rows[1] = text(translate("No industry types match this filter."), "font-scale-annotation") end
		children[#children + 1] = row({
			cell("il-col-icon", text("", "font-scale-annotation")),
			cell("il-col-name", text(translate("Industry type"), "font-scale-annotation")),
			cell("il-col-count", text(translate("Built"), "font-scale-annotation")),
			cell("il-col-limit", text(translate("Limit"), "font-scale-annotation")),
			cell("il-col-block", text(translate("New ones"), "font-scale-annotation")),
		})
		children[#children + 1] = scroll(rows)
		if anyBlocked then
			children[#children + 1] = builtin.Button{
				meta = { class = "secondary" },
				content = text(translate("Allow all types again")),
				onClick = function() send(il.clearBlockedEvent) end,
			}
		end
        return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
    end)
    local MenuWindow = react.RegisterWrapperRecipe("IndustryLimitWindow", builtin.Window, function(params)
        return builtin.Window{
            meta = { class = "il-window" },
            id = "industrylimit.window",
            initialX = 0.5,
            initialY = 0.5,
            title = translate("Industry Limit"),
            onClose = params.onClose,
            closable = true,
            movable = true,
            autoFocusOnBecomingVisible = true,
            content = Content{},
        }
    end)

    local Button = react.RegisterPluginRecipe(modArea.MainModButtonAreaExtension, "IndustryLimitButton", function()
        local openState = react.useState(false)
        notifyWindowGone = function() openState:set(false) end
        local function close()
            local winApi = windowApiInUse or globals.getDefaultWindowApi()
            if winApi then winApi.removeAllWindows(MenuWindow) end
            windowIsOpen = false
            windowApiInUse = nil
            openState:set(false)
        end
        local function open()
            local winApi = globals.getDefaultWindowApi()
            if not winApi then return end
            winApi.addSingletonWindow(MenuWindow, { onClose = close })
            windowIsOpen = true
            windowApiInUse = winApi
            openState:set(true)
        end
        return builtin.BoxLayout{
            children = {
                builtin.ToggleButton{
                    meta = { tooltip = translate("Industry Limit"), class = "il-toolbar-btn" },
                    content = builtin.ImageView{
                        meta = { class = "il-toolbar-icon" },
                        path = ICON.toolbar,
                        scaling = builtin.type.ImageViewScaling.AutoFit,
                    },
                    value = (openState:old() == true) and 1 or 0,
                    onValueChange = function(value)
                        if value == 1 and not windowIsOpen then open()
                        elseif value == 0 and windowIsOpen then close()
                        else openState:set(windowIsOpen) end
                    end,
                },
            },
        }
    end)

    return { IndustryLimitButton = Button }
end
