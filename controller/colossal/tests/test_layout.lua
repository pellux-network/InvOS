local Layout = require("app.layout")
local T = require("tests.mock_cc")

return {
    { name = "the standard terminal gets every region", run = function()
        local regions = Layout.regions(51, 19)
        T.equal(regions.header, 1)
        T.equal(regions.nav, 2)
        T.equal(regions.content.top, 3)
        T.equal(regions.content.bottom, 16)
        T.equal(regions.strip, 17)
        T.equal(regions.footer, 18)
        T.equal(regions.status, 19)
    end },
    { name = "regions never overlap and never leave a gap", run = function()
        for _, size in ipairs({{51,19},{79,24},{26,12},{18,8},{40,10}}) do
            local regions = Layout.regions(size[1], size[2])
            local label = size[1] .. "x" .. size[2]
            T.equal(regions.content.top > regions.nav, true, label .. " content overlaps nav")
            local below = regions.strip or regions.footer
            T.equal(regions.content.bottom, below - 1, label .. " leaves a gap or overlaps")
            T.equal(regions.footer, regions.status - 1, label .. " footer overlaps status")
            T.equal(regions.status, size[2], label .. " status is not the last row")
        end
    end },
    { name = "the detail pane appears at 40 columns, not at 72", run = function()
        T.equal(Layout.regions(39, 19).split, nil)
        T.equal(Layout.regions(51, 19).split ~= nil, true,
            "the approved design shows a detail pane on the 51-column terminal")
        T.equal(Layout.regions(51, 19).split < 51, true)
    end },
    { name = "wide is a separate, larger threshold than the pane", run = function()
        T.equal(Layout.regions(51, 19).wide, false)
        T.equal(Layout.regions(79, 24).wide, true)
    end },
    { name = "a short screen drops the strip and gives the row back to content", run = function()
        local short = Layout.regions(51, 8)
        T.equal(short.strip, nil, "a screen this small needs its rows for content")
        T.equal(short.content.bottom, 6)
        T.equal(short.footer, 7)
        T.equal(short.status, 8)
    end },
    { name = "content is never inverted, even on an absurd screen", run = function()
        for _, size in ipairs({{51,6},{10,5},{8,4}}) do
            local regions = Layout.regions(size[1], size[2])
            T.equal(regions.content.bottom >= regions.content.top - 1, true,
                size[1] .. "x" .. size[2] .. " produced an inverted content band")
        end
    end },
}
