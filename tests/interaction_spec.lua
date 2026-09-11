describe("editor interactions", function()
    local editor
    local initial = "- [ ] Example task (@[[2026-02-17]])"

    local function open_source(path)
        editor.command("edit " .. vim.fn.fnameescape(path or editor.path))
        editor.wait("return vim.bo.filetype == 'markdown'", "Markdown mappings did not load")
    end

    local function changed_line(expected, row)
        editor.wait(
            [[
            local expected, row = ...
            for _, lines in ipairs(_G.test_changes) do
                if lines[row] == expected then return true end
            end
            return false
        ]],
            "TextChanged did not report the task edit to renderers",
            expected,
            row or 1
        )
    end

    local function wait_for_marker(marker)
        editor.wait(
            [[
            return vim.api.nvim_get_current_line():find(..., 1, true) ~= nil
        ]],
            "keypress did not apply " .. marker,
            marker
        )
        editor.no_warnings()
    end

    local function ready_tasks(expected)
        editor.wait(
            [[
            return not require('taskbuffer.buffer').get_refreshing()
                and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find(..., 1, true) ~= nil
        ]],
            "task list did not publish the expected content",
            expected
        )
        editor.no_warnings()
    end

    before_each(function()
        editor = require("tests.helpers.editor").new()
    end)

    after_each(function()
        if editor then
            editor.close()
            editor = nil
        end
    end)

    it("opens, refreshes, and reopens real taskfiles without W10 or W13", function()
        assert.is_false(editor.lua("return package.loaded['taskbuffer.scan'] ~= nil"))
        assert.is_false(editor.lua("return package.loaded['taskbuffer.source'] ~= nil"))
        editor.command("Tasks")
        ready_tasks("Example task")
        local buf = editor.lua("return vim.api.nvim_get_current_buf()")
        assert.is_true(editor.lua("return vim.bo.readonly and not vim.bo.modified"))
        vim.fn.writefile({ "- [ ] Refreshed task (@[[2026-02-17]])" }, editor.path)
        editor.command("Tasks")
        ready_tasks("Refreshed task")
        assert.is_true(editor.lua("return vim.bo.readonly and not vim.bo.modified"))
        editor.command("enew")
        editor.command("Tasks")
        ready_tasks("Refreshed task")
        assert.are.equal(buf, editor.lua("return vim.api.nvim_get_current_buf()"))
        assert.is_true(editor.lua("return vim.bo.readonly and not vim.bo.modified and not vim.bo.swapfile"))
    end)

    it("delivers checkbox changes to renderers when marking a saved task irrelevant", function()
        open_source()
        if vim.env.TASKBUFFER_TEST_OBSIDIAN then
            editor.wait(
                [[
                for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0,
                    vim.api.nvim_create_namespace('ObsidianUI'), 0, -1, { details = true })) do
                    if (mark[4].hl_group or ''):lower() == 'obsidiantodo' then return true end
                end
                return false
            ]],
                "Obsidian did not render the initial open checkbox"
            )
        end
        editor.lua("_G.test_changes = {}")
        editor.input("<Space>ti")
        wait_for_marker("::irrelevant")
        local line = editor.lines()[1]
        changed_line(line)
        assert.is_truthy(line:find("- [-] Example task", 1, true))
        if vim.env.TASKBUFFER_TEST_OBSIDIAN then
            editor.wait(
                [[
                for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0,
                    vim.api.nvim_create_namespace('ObsidianUI'), 0, -1, { details = true })) do
                    if (mark[4].hl_group or ''):lower() == 'obsidiantodo' then return false end
                end
                return true
            ]],
                "Obsidian retained the stale open-checkbox decoration"
            )
        end
        assert.is_true(editor.lua("return vim.bo.modified"))
        assert.are.same({ initial, "Saved paragraph" }, vim.fn.readfile(editor.path))
    end)

    it("marks an edited and moved task irrelevant, with one native undo step", function()
        open_source()
        editor.input("ggOUnsaved heading<Esc>j$A edited<Esc>")
        editor.wait("return vim.api.nvim_get_current_line():find(' edited$', 1) ~= nil", "typing was not applied")
        local before = editor.lines()
        local cursor = editor.lua("return vim.api.nvim_win_get_cursor(0)")
        editor.lua("_G.test_changes = {}")
        editor.input("<Space>ti")
        wait_for_marker("::irrelevant")
        local marked = editor.lines()
        changed_line(marked[2], 2)
        assert.is_truthy(marked[2]:find("- [-] Example task", 1, true))
        assert.is_truthy(marked[2]:find(" edited ::irrelevant", 1, true))
        assert.are.equal(before[1], marked[1])
        assert.are.equal(before[3], marked[3])
        assert.are.same(cursor, editor.lua("return vim.api.nvim_win_get_cursor(0)"))
        editor.input("u")
        editor.wait(
            "return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), ...)",
            "undo lost user edits",
            before
        )
        editor.input("<C-r>")
        editor.wait(
            "return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), ...)",
            "redo did not restore the action",
            marked
        )
        editor.input("<Space>tu")
        editor.wait(
            "return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), ...)",
            "unset did not restore the task",
            before
        )
        assert.is_true(editor.lua("return vim.bo.modified"))
        assert.are.same({ initial, "Saved paragraph" }, vim.fn.readfile(editor.path))
        editor.no_warnings()
    end)

    for _, name in ipairs({ "new file", "unnamed buffer" }) do
        it("marks a task irrelevant before saving a " .. name, function()
            local path = editor.root .. "/vault/new.md"
            if name == "new file" then
                open_source(path)
            else
                editor.command("enew")
                editor.command("setfiletype markdown")
            end
            editor.input("i- [ ] New task<Esc>")
            editor.wait("return vim.api.nvim_get_current_line() == '- [ ] New task'", "new task was not entered")
            editor.input("<Space>ti")
            wait_for_marker("- [-] New task ::irrelevant")
            assert.are.equal(0, vim.fn.filereadable(path))
            assert.is_true(editor.lua("return vim.bo.modified"))
        end)
    end

    for _, case in ipairs({
        { key = "tc", expected = "::complete", checkbox = "- [x]" },
        { key = "tx", expected = "- [x]", checkbox = "- [x]" },
        { key = "td", expected = "::deferral", checkbox = "- [ ]" },
    }) do
        it("applies <leader>" .. case.key .. " to an unsaved source buffer", function()
            open_source()
            editor.input("GoUnsaved paragraph<Esc>gg")
            editor.wait("return vim.bo.modified and vim.api.nvim_win_get_cursor(0)[1] == 1", "editing did not finish")
            local before = editor.lines()
            editor.input("<Space>" .. case.key)
            wait_for_marker(case.expected)
            local after = editor.lines()
            assert.are.equal(case.checkbox, after[1]:sub(1, #case.checkbox))
            assert.are.equal(before[3], after[3])
            changed_line(after[1])
            editor.input("u")
            editor.wait(
                "return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), ...)",
                "undo lost edits",
                before
            )
            assert.are.same({ initial, "Saved paragraph" }, vim.fn.readfile(editor.path))
        end)
    end

    for _, frontmatter in ipairs({ false, true }) do
        it("edits an unsaved " .. (frontmatter and "frontmatter" or "inline") .. " date through its keys", function()
            local lines = frontmatter and { "---", "due: 2026-02-17", "---", "- [ ] Example task" } or { initial }
            vim.fn.writefile(lines, editor.path)
            open_source()
            editor.input("GoUnsaved paragraph<Esc>k")
            editor.wait(
                "return vim.bo.modified and vim.api.nvim_get_current_line():find('Example task', 1, true) ~= nil",
                "editing did not finish"
            )
            local before = editor.lines()
            editor.input("<M-Right>")
            local row = frontmatter and 2 or 1
            editor.wait(
                [[
                local row = ...
                return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]:find('2026-02-18', 1, true) ~= nil
            ]],
                "date mapping did not shift the current buffer",
                row
            )
            changed_line(editor.lines()[row], row)
            editor.input("u")
            editor.wait(
                "return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), ...)",
                "date undo lost edits",
                before
            )
            editor.input("<C-T>")
            editor.wait(
                [[
                local row = ...
                return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]:find(os.date('%Y-%m-%d'), 1, true) ~= nil
            ]],
                "set-today mapping did not update the buffer",
                row
            )
            assert.are.same(lines, vim.fn.readfile(editor.path))
            assert.is_true(editor.lua("return vim.bo.modified"))
            editor.no_warnings()
        end)
    end

    it("protects a hidden dirty source, then allows editing it after navigation", function()
        open_source()
        editor.input("GoUnsaved paragraph<Esc>gg")
        editor.wait("return vim.bo.modified", "source was not edited")
        local before = editor.lines()
        local source_buf = editor.lua("return vim.api.nvim_get_current_buf()")
        editor.command("Tasks")
        ready_tasks("Example task")
        editor.lua(
            [[
            local path = ...
            for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
                if line:find(path .. ':1:', 1, true) then vim.api.nvim_win_set_cursor(0, {i, 0}); return end
            end
            error('missing source task')
        ]],
            editor.path
        )
        editor.input("<Space>ti")
        editor.wait("return #_G.test_warnings > 0", "aggregate action did not protect unsaved source edits")
        assert.is_truthy(editor.lua("return _G.test_warnings[1]"):find("unsaved", 1, true))
        assert.are.same(before, editor.lua("return vim.api.nvim_buf_get_lines(..., 0, -1, false)", source_buf))
        assert.are.same({ initial, "Saved paragraph" }, vim.fn.readfile(editor.path))
        editor.lua("_G.test_warnings = {}; vim.v.warningmsg = ''; vim.v.errmsg = ''; vim.cmd('messages clear')")
        editor.input("gf")
        editor.wait(
            "return vim.api.nvim_get_current_buf() == ...",
            "gf did not return to the source buffer",
            source_buf
        )
        editor.input("<Space>ti")
        wait_for_marker("- [-] Example task")
        assert.are.equal("Unsaved paragraph", editor.lines()[3])
        assert.are.same({ initial, "Saved paragraph" }, vim.fn.readfile(editor.path))
        editor.no_warnings()
    end)
end)
