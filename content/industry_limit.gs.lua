-- Game script declaration. Its resource path (industry_limit::/industry_limit.gs)
-- keys the saved state; do not rename it after release.
function data()
    return {
        updateScript = { fileName = "industry_limit::/industry_limit.script@update" },
        postUpdateScript = { fileName = "industry_limit::/industry_limit.script@postUpdate" },
        handleEventScript = { fileName = "industry_limit::/industry_limit.script@handleEvent" },
    }
end
