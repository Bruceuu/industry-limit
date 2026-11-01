-- Keep this stylesheet minimal: a failing stylesheet can silently remove the toolbar button.
-- Selector grammar (gui/main/stylesheetutil.lua): Element!class; classes and ids must not contain "_".
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
    local result = {}
    local add = ssu.makeAdder(result)
    add("R::IndustryLimitButton ToggleButton!il-toolbar-btn", {
        size = { 32, 32 }, minSize = { 32, 32 }, maxSize = { 32, 32 },
        padding = { 4, 4, 4, 4 }, margin = { 1, 1, 2, 1 }, gravity = { 0.5, 0.5 },
    })
    add("R::IndustryLimitButton !il-toolbar-icon", {
        size = { 24, 24 }, minSize = { 24, 24 }, maxSize = { 24, 24 }, gravity = { 0.5, 0.5 },
    })
    add("Window!il-window", { anchorPoint = { 0.5, 0.5 } })
    add("Window!il-window Window::Content", { padding = { 8, 12, 12, 12 } })
    add("Window!il-window BoxLayout", { innerSpacing = { 6, 6 } })
    add("Window!il-window !il-scroll", { minSize = { 854, 480 }, maxSize = { -1, 480 } })
    add("Window!il-window TextView!il-wrap", { textAutoWrap = true, maxSize = { 854, -1 } })
    add("Window!il-window TextView!il-wrap-short", { textAutoWrap = true, maxSize = { 460, -1 } })
    add("Window!il-window TextView!il-wrap-col", { textAutoWrap = true, maxSize = { 296, -1 } })
    add("Window!il-window !il-type-icon", { size = { 48, 30 }, minSize = { 48, 30 }, maxSize = { 48, 30 }, gravity = { 0.5, 0.5 } })
    add("Window!il-window !il-btn-icon", { size = { 18, 18 }, minSize = { 18, 18 }, maxSize = { 18, 18 }, gravity = { 0.5, 0.5 } })
    -- Table columns: fixed-width Component cells (header and rows share the classes, so they align).
    add("Window!il-window !il-cell", { padding = {6, 6, 6, 6,}, gravity = { 0, 0.5 } })
    add("Window!il-window !il-col-icon", { minSize = { 86, 0 }, maxSize = { 86, 10000 } })
    add("Window!il-window !il-col-name", { minSize = { 300, 0 }, maxSize = { 300, 10000 } })
    add("Window!il-window !il-col-count", { minSize = { 60, 0 }, maxSize = { 60, 10000 } })
	add("Window!il-window !il-col-limit", { minSize = { 150, 0 }, maxSize = { 150, 10000 } })
    add("Window!il-window !il-col-block", { minSize = { 140, 0 }, maxSize = { 140, 10000 } })
    add("Window!il-window !il-cargo-icon", { size = { 24, 24 }, minSize = { 24, 24 }, maxSize = { 24, 24 }, gravity = { 0.5, 0.5 } })
    -- Industry window card (entity window plugin).
    add("R::IndustryLimitControls !il-btn-icon", { size = { 18, 18 }, minSize = { 18, 18 }, maxSize = { 18, 18 }, gravity = { 0.5, 0.5 } })
    add("R::IndustryLimitControls TextView!il-card-text", { textAutoWrap = true, maxSize = { 360, -1 } })
    return result
end
