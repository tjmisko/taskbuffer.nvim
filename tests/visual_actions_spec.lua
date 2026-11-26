-- Task verbs over a visual selection in the task list.
describe("visual task actions", function()
    local editor
    local other

    local function ready_tasks(expected)
        editor.wait(
            [[
            return not require('taskbuffer.buffer').get_refreshing()
                and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find(..., 1, true) ~= nil
        ]],
            "task list did not publish the expected content",
            expected
        )
    end

    local function wait_file(path, expected, reason)
        editor.wait("local p, e = ...; return vim.deep_equal(vim.fn.readfile(p), e)", reason, path, expected)
    end

    local function row_of(text)
        return editor.lua(
            [[
            for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
                if line:find(..., 1, true) then return i end
            end
        ]],
            text
        )
    end

    local function notifications()
        return editor.lua("return _G.test_notes")
    end

    before_each(function()
        editor = require("tests.helpers.editor").new()
        other = editor.root .. "/vault/z.md"
        vim.fn.writefile({
            "- [ ] Alpha (@[[2026-02-17]])",
            "- [ ] Bravo (@[[2026-02-17]])",
            "- [ ] Charlie (@[[2026-02-17]])",
        }, editor.path)
        vim.fn.writefile({ "# Other", "- [ ] Delta (@[[2026-02-17]])" }, other)
        editor.lua([[
            _G.test_notes = {}
            local notify = vim.notify
            vim.notify = function(message, level, opts)
                table.insert(_G.test_notes, message)
                notify(message, level, opts)
            end
        ]])
        editor.command("Tasks")
        ready_tasks("Delta")
    end)

    after_each(function()
        if editor then
            editor.close()
            editor = nil
        end
    end)

    it("should mark every selected task irrelevant when a linewise selection covers the list", function()
        editor.input("ggVG<Space>ti")
        editor.wait(
            [[
            local lines = vim.fn.readfile(...)
            for i, name in ipairs({ 'Alpha', 'Bravo', 'Charlie' }) do
                if not lines[i]:match('^%- %[%-%] ' .. name .. ' %(@%[%[2026%-02%-17%]%]%) ::irrelevant %[%[') then
                    return false
                end
            end
            return true
        ]],
            "first source was not marked irrelevant",
            editor.path
        )
        editor.wait(
            "return vim.fn.readfile(...)[2]:find('- [-] Delta', 1, true) ~= nil",
            "second source was not marked irrelevant",
            other
        )
        editor.wait("return vim.fn.mode() == 'n'", "visual mode was not left")
        editor.no_warnings()
        assert.are.same({ "[taskbuffer] marked irrelevant 4 tasks" }, notifications())
    end)

    it("should revert the whole selection with one undo when tasks were completed in bulk", function()
        editor.input("ggVG<Space>tc")
        editor.wait(
            "return vim.fn.readfile(...)[2]:find('- [x] Delta', 1, true) ~= nil",
            "bulk complete did not reach the second source",
            other
        )
        editor.wait(
            "return vim.fn.readfile(...)[3]:find('- [x] Charlie', 1, true) ~= nil",
            "bulk complete did not reach the first source",
            editor.path
        )
        editor.input("u")
        wait_file(editor.path, {
            "- [ ] Alpha (@[[2026-02-17]])",
            "- [ ] Bravo (@[[2026-02-17]])",
            "- [ ] Charlie (@[[2026-02-17]])",
        }, "undo did not restore the first source")
        wait_file(other, { "# Other", "- [ ] Delta (@[[2026-02-17]])" }, "undo did not restore the second source")
        ready_tasks("Delta")
        editor.no_warnings()
    end)

    it("should act on only the rows a blockwise selection spans", function()
        local bravo, charlie = row_of("Bravo"), row_of("Charlie")
        editor.input(bravo .. "G3|<C-v>" .. charlie .. "G5|<Space>tx")
        wait_file(editor.path, {
            "- [ ] Alpha (@[[2026-02-17]])",
            "- [x] Bravo (@[[2026-02-17]])",
            "- [x] Charlie (@[[2026-02-17]])",
        }, "blockwise check-off changed the wrong tasks")
        assert.are.same({ "# Other", "- [ ] Delta (@[[2026-02-17]])" }, vim.fn.readfile(other))
        editor.no_warnings()
    end)

    it("should act on every row a charwise selection touches, skipping heading rows", function()
        -- Start on the heading above the first task; end mid-line on Alpha.
        local alpha = row_of("Alpha")
        assert.is_true(alpha > 1)
        editor.input((alpha - 1) .. "G$v" .. alpha .. "G2|<Space>ti")
        editor.wait(
            "return vim.fn.readfile(...)[1]:find('- [-] Alpha', 1, true) ~= nil",
            "charwise selection did not mark Alpha",
            editor.path
        )
        assert.are.equal("- [ ] Bravo (@[[2026-02-17]])", vim.fn.readfile(editor.path)[2])
        editor.no_warnings()
    end)

    it("should apply defer to every selected task", function()
        local alpha, bravo = row_of("Alpha"), row_of("Bravo")
        editor.input(alpha .. "GV" .. bravo .. "G<Space>td")
        editor.wait(
            [[
            local lines = vim.fn.readfile(...)
            return lines[1]:find('::deferral', 1, true) ~= nil and lines[2]:find('::deferral', 1, true) ~= nil
        ]],
            "defer did not reach both selected tasks",
            editor.path
        )
        local lines = vim.fn.readfile(editor.path)
        assert.is_truthy(lines[1]:find("::original [[2026-02-17]]", 1, true))
        assert.is_nil(lines[3]:find("::", 1, true))
        editor.no_warnings()
    end)

    it("should change nothing when any selected row is stale", function()
        vim.fn.writefile({ "Inserted heading", "# Other", "- [ ] Delta (@[[2026-02-17]])" }, other)
        editor.input("ggVG<Space>ti")
        editor.wait("return #_G.test_warnings > 0", "stale selection was not rejected")
        assert.are.same({
            "- [ ] Alpha (@[[2026-02-17]])",
            "- [ ] Bravo (@[[2026-02-17]])",
            "- [ ] Charlie (@[[2026-02-17]])",
        }, vim.fn.readfile(editor.path))
    end)

    it("should warn and change nothing when the selection holds no tasks", function()
        editor.input("ggV<Space>ti")
        editor.wait("return #_G.test_warnings > 0", "empty selection did not warn")
        assert.are.same({ "[taskbuffer] no tasks in selection" }, editor.lua("return _G.test_warnings"))
        assert.are.equal("- [ ] Alpha (@[[2026-02-17]])", vim.fn.readfile(editor.path)[1])
    end)

    it("should skip a task that is no longer open without mutating it", function()
        -- Close Alpha in its source buffer view of the index, keeping the row valid:
        -- the list still shows it, so drive the util entry point directly.
        local result = editor.lua(
            [[
            local path = ...
            local buffer = require('taskbuffer.buffer')
            local tasks = buffer.tasks_in_rows({ 1, 2, 3, 4, 5, 6, 7, 8 })
            local alpha
            for _, t in ipairs(tasks) do if t.body == 'Alpha' then alpha = t end end
            -- Pretend the task were done: the verb must refuse it, not stack markers.
            local parse = require('taskbuffer.parse')
            local real = parse.parse_task
            parse.parse_task = function(item, ctx)
                local task = real(item, ctx)
                if task and task.body == 'Alpha' then task.status = 'done' end
                return task
            end
            local ok = require('taskbuffer.util').run_task_cmd_bulk('complete-at', { alpha })
            parse.parse_task = real
            return { ok = ok, line = vim.fn.readfile(path)[1], notes = _G.test_notes }
        ]],
            editor.path
        )
        assert.is_false(result.ok)
        assert.are.equal("- [ ] Alpha (@[[2026-02-17]])", result.line)
        assert.are.same({ "[taskbuffer] nothing to change; skipped 1 not open" }, result.notes)
    end)

    it("should roll back a half-applied verb and keep earlier edits undoable when a write fails", function()
        local result = editor.lua([[
            local buffer = require('taskbuffer.buffer')
            local tasks = buffer.tasks_in_rows({ 1, 2, 3, 4, 5, 6, 7, 8 })
            table.sort(tasks, function(a, b) return a.body < b.body end)
            local mutate = require('taskbuffer.mutate')
            local real = mutate.change_checkbox
            -- Bravo's marker lands, then its checkbox write fails.
            mutate.change_checkbox = function(path, lnum, from, to)
                if lnum == 2 and path:match('tasks%.md$') then return false, 'disk full' end
                return real(path, lnum, from, to)
            end
            local ok = require('taskbuffer.util').run_task_cmd_bulk('complete-at', tasks)
            mutate.change_checkbox = real
            return { ok = ok, notes = _G.test_notes }
        ]])
        assert.is_false(result.ok)
        editor.wait(
            "return vim.fn.readfile(...)[1]:find('- [x] Alpha', 1, true) ~= nil",
            "the task before the failure was not completed",
            editor.path
        )
        local lines = vim.fn.readfile(editor.path)
        assert.are.equal("- [ ] Bravo (@[[2026-02-17]])", lines[2])
        assert.are.equal("- [ ] Charlie (@[[2026-02-17]])", lines[3])
        assert.are.same({ "# Other", "- [ ] Delta (@[[2026-02-17]])" }, vim.fn.readfile(other))
        assert.is_truthy(result.notes[#result.notes]:find("completed 1 of 4 tasks, then failed at", 1, true))
        editor.input("u")
        wait_file(editor.path, {
            "- [ ] Alpha (@[[2026-02-17]])",
            "- [ ] Bravo (@[[2026-02-17]])",
            "- [ ] Charlie (@[[2026-02-17]])",
        }, "undo did not revert the applied part of the selection")
    end)

    it("should not map a visual verb whose key is disabled", function()
        local mapped = editor.lua([[
            require('taskbuffer').setup({ keymaps = { taskfile = { irrelevant = false }, global = { irrelevant = '<leader>ti' } } })
            pcall(vim.keymap.del, 'x', '<Space>ti', { buffer = 0 })
            pcall(vim.keymap.del, 'x', '<Space>tc', { buffer = 0 })
            require('taskbuffer.keymaps').attach_taskfile()
            local m = vim.fn.maparg('<Space>ti', 'x', false, true)
            local c = vim.fn.maparg('<Space>tc', 'x', false, true)
            return { ti = m.buffer == 1, tc = c.buffer == 1 }
        ]])
        assert.is_false(mapped.ti)
        assert.is_true(mapped.tc)
    end)
end)
