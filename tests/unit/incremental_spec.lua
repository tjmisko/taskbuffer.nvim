local format = require("taskbuffer.format")
local strftime = require("taskbuffer.strftime")
local horizon = require("taskbuffer.horizon")

local day = 86400
local noon = strftime.date_to_epoch(2026, 9, 11)

local function task(path, row, fields)
    return vim.tbl_extend("force", {
        file_path = path,
        line_number = row,
        body = "Task " .. row,
        status = "open",
        tags = {},
        markers = {},
        due_time = "",
        duration = "",
    }, fields or {})
end

local function vault()
    return {
        task("/a.md", 1, { due_date = noon - 3 * day, tags = { "work" } }),
        task("/a.md", 2, { due_date = noon, due_time = "09:00", duration = "30m", tags = { "home" } }),
        task("/a.md", 3, {
            due_date = noon + day,
            markers = { { kind = "start", date = "2026-09-11", time = "08:00" } },
        }),
        task("/b.md", 1, { due_date = noon + 20 * day, tags = { "work" } }),
        task("/b.md", 2),
        task("/b.md", 3, { tags = { "home", "work" } }),
    }
end

local option_sets = {
    { name = "defaults", opts = {} },
    { name = "markers", opts = { markers = true } },
    { name = "ignore_undated", opts = { ignore_undated = true } },
    { name = "tag filter", opts = { tag_filter = { "work" } } },
    { name = "custom date format", opts = { date_strftime = "%d/%m/%Y" } },
    { name = "narrowest overlap", opts = { overlap = "narrowest" } },
    { name = "first_match overlap", opts = { overlap = "first_match" } },
    { name = "custom prefixes", opts = { markers = true, tag_prefix = "+", marker_prefix = "@@" } },
}

local function render(tasks, opts)
    local view = format.format_view(tasks, noon, vim.tbl_extend("force", {}, opts))
    return table.concat(view.lines, "\n")
end

-- Fresh copies carry no cached rows: the reference full render.
local function cold(tasks)
    local copies = {}
    for index, item in ipairs(tasks) do
        copies[index] = vim.deepcopy(item)
        copies[index]._row_cache = nil
    end
    return copies
end

describe("cached task rows", function()
    for _, case in ipairs(option_sets) do
        it("should render the same text as a cold render when one task changes with " .. case.name, function()
            local tasks = vault()
            render(tasks, case.opts) -- warm every row
            local changed = vim.list_slice(tasks)
            changed[2] = task("/a.md", 2, { due_date = noon + 2 * day, body = "Changed", tags = { "work" } })
            assert.are.equal(render(cold(changed), case.opts), render(changed, case.opts))
        end)

        it("should render the same text as a cold render when one task is added with " .. case.name, function()
            local tasks = vault()
            render(tasks, case.opts)
            tasks[#tasks + 1] = task("/c.md", 1, { due_date = noon, tags = { "work" }, duration = "1h" })
            assert.are.equal(render(cold(tasks), case.opts), render(tasks, case.opts))
        end)

        it("should render the same text as a cold render when one task is removed with " .. case.name, function()
            local tasks = vault()
            render(tasks, case.opts)
            table.remove(tasks, 3)
            assert.are.equal(render(cold(tasks), case.opts), render(tasks, case.opts))
        end)
    end

    it("should reuse the rendered row when nothing about the task changed", function()
        local tasks = vault()
        render(tasks, {})
        local cache = tasks[2]._row_cache
        render(tasks, {})
        assert.are.equal(cache, tasks[2]._row_cache)
    end)

    it("should re-render rows when the marker option flips between renders", function()
        local tasks = vault()
        local plain = render(tasks, { markers = false })
        local marked = render(tasks, { markers = true })
        assert.are_not.equal(plain, marked)
        assert.is_truthy(marked:find("::start", 1, true))
        assert.are.equal(plain, render(tasks, { markers = false }))
    end)

    it("should re-render the row when the task body is edited in place", function()
        local tasks = vault()
        render(tasks, {})
        tasks[1].body = "Edited in place"
        assert.is_truthy(render(tasks, {}):find("Edited in place", 1, true))
    end)

    it("should re-render rows when the date format changes", function()
        local tasks = vault()
        render(tasks, {})
        assert.is_truthy(render(tasks, { date_strftime = "%d/%m/%Y" }):find("11/09/2026", 1, true))
    end)

    it("should keep taskfile export unaffected by the row cache", function()
        local tasks = vault()
        local horizons = horizon.resolve(nil, noon, horizon.MONDAY, "sorted")
        local before = format.format_taskfile(tasks, noon, { horizons = horizons })
        render(tasks, {})
        assert.are.equal(before, format.format_taskfile(tasks, noon, { horizons = horizons }))
    end)
end)
