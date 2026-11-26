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

describe("merged sort order on a large vault", function()
    local function big_vault()
        local tasks = {}
        for file = 1, 4 do
            for row = 1, 20 do
                tasks[#tasks + 1] = task("/f" .. file .. ".md", row, {
                    due_date = noon + ((file * 7 + row * 3) % 25 - 10) * day,
                })
            end
        end
        for file = 5, 8 do
            for row = 1, 20 do
                tasks[#tasks + 1] = task("/f" .. file .. ".md", row)
            end
        end
        return tasks
    end

    local function shuffled(tasks, seed)
        math.randomseed(seed)
        local copy = vim.list_slice(tasks)
        for i = #copy, 2, -1 do
            local j = math.random(i)
            copy[i], copy[j] = copy[j], copy[i]
        end
        return copy
    end

    -- Warm render first: a cold render of copies would replace the remembered order.
    local function assert_warm_equals_cold(tasks)
        local warm = render(tasks, {})
        assert.are.equal(render(cold(tasks), {}), warm)
    end

    it("should match a cold render when a task is replaced and moves across buckets", function()
        local tasks = big_vault()
        render(tasks, {})
        tasks[5] = task("/f1.md", 5, { due_date = noon + 40 * day, body = "Moved" })
        assert_warm_equals_cold(tasks)
    end)

    it("should match a cold render when a task is removed", function()
        local tasks = big_vault()
        render(tasks, {})
        table.remove(tasks, 10)
        assert_warm_equals_cold(tasks)
    end)

    it("should match a cold render when a few tasks are added", function()
        local tasks = big_vault()
        render(tasks, {})
        tasks[#tasks + 1] = task("/f1.md", 99, { due_date = noon })
        tasks[#tasks + 1] = task("/f9.md", 1)
        tasks[#tasks + 1] = task("/f0.md", 1, { due_date = noon - 30 * day })
        assert_warm_equals_cold(tasks)
    end)

    it("should match a cold render when a task moves from dated to undated", function()
        local tasks = big_vault()
        render(tasks, {})
        tasks[3] = task("/f1.md", 3)
        assert_warm_equals_cold(tasks)
    end)

    it("should match a cold render when a task moves from undated to dated", function()
        local tasks = big_vault()
        render(tasks, {})
        tasks[100] = task("/f6.md", 20, { due_date = noon + day })
        assert_warm_equals_cold(tasks)
    end)

    it("should match a cold render when the input order is shuffled between renders", function()
        local tasks = big_vault()
        render(shuffled(tasks, 1), {})
        tasks[7] = task("/f1.md", 7, { due_date = noon - 5 * day, body = "Replaced" })
        table.remove(tasks, 90)
        assert_warm_equals_cold(shuffled(tasks, 2))
    end)

    it("should match a cold render when a due date is mutated in place", function()
        local tasks = big_vault()
        render(tasks, {})
        tasks[4].due_date = noon + 100 * day
        tasks[30].due_date = noon - 100 * day
        assert_warm_equals_cold(tasks)
    end)

    it("should match a cold render when more than a quarter of the tasks are new", function()
        local tasks = big_vault()
        render(tasks, {})
        for index = 1, 60 do
            tasks[index] = task("/n.md", index, { due_date = noon + (index % 9) * day })
        end
        assert_warm_equals_cold(tasks)
    end)

    it("should match a cold render when the same task object appears twice", function()
        local tasks = big_vault()
        render(tasks, {})
        tasks[#tasks + 1] = tasks[2]
        assert_warm_equals_cold(tasks)
    end)

    it("should match a cold render after several successive edits", function()
        local tasks = big_vault()
        render(tasks, {})
        for step = 1, 6 do
            tasks[step * 11] = task("/f" .. step .. ".md", 50 + step, { due_date = noon + step * day })
            assert_warm_equals_cold(tasks)
        end
    end)
end)
