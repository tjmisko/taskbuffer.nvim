describe("dot-repeat of task actions", function()
    local editor

    local function wait_lines(expected, reason)
        editor.wait("return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), ...)", reason, expected)
    end

    local function wait_file(path, predicate, reason)
        local ready = vim.wait(3000, function()
            return predicate(vim.fn.readfile(path))
        end, 10)
        assert(ready, reason .. ": " .. vim.inspect(vim.fn.readfile(path)))
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
    end

    -- A fresh file per call: re-editing a markdown buffer runs Neovim's own
    -- b:undo_ftplugin, which leaves an unrelated E31 in v:errmsg.
    local function open_source(lines, name)
        local path = name and (editor.root .. "/vault/" .. name) or editor.path
        vim.fn.writefile(lines, path)
        editor.command("edit " .. vim.fn.fnameescape(path))
        editor.wait("return vim.bo.filetype == 'markdown'", "Markdown mappings did not load")
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

    it("should repeat the action instead of the last text edit when pressing dot after <leader>td", function()
        open_source({ "- [ ] First (@[[2026-02-17]])", "- [ ] Second (@[[2026-02-18]])", "Paragraph" })
        editor.input("GA typed<Esc>gg<Space>td")
        editor.wait("return vim.api.nvim_get_current_line():find('::deferral', 1, true) ~= nil", "defer not applied")
        editor.input("j.")
        editor.wait(
            "return vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:find('::deferral', 1, true) ~= nil",
            "dot did not repeat defer on the second task"
        )
        local lines = editor.lines()
        assert.are.equal("Paragraph typed", lines[3])
        assert.is_truthy(lines[2]:find("::original [[2026-02-18]]", 1, true))
        assert.are.equal(2, editor.lua("return vim.api.nvim_win_get_cursor(0)[1]"))
        editor.no_warnings()
    end)

    it("should undo one repeated action per u when actions run in a source buffer", function()
        open_source({ "- [ ] First", "- [ ] Second", "- [ ] Third" })
        local original = editor.lines()
        editor.input("<Space>ti")
        editor.wait("return vim.api.nvim_get_current_line():find('::irrelevant', 1, true) ~= nil", "first not marked")
        local after_first = editor.lines()
        editor.input("j.")
        editor.wait(
            "return vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:find('::irrelevant', 1, true) ~= nil",
            "second not marked"
        )
        local after_second = editor.lines()
        editor.input("j.")
        editor.wait(
            "return vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]:find('::irrelevant', 1, true) ~= nil",
            "third not marked"
        )
        assert.are.equal("- [ ] Third", after_second[3])
        editor.input("u")
        wait_lines(after_second, "first undo did not revert only the third task")
        editor.input("u")
        wait_lines(after_first, "second undo did not revert only the second task")
        editor.input("u")
        wait_lines(original, "third undo did not revert the first task")
        editor.input("<C-r>")
        wait_lines(after_first, "redo did not restore one action")
        editor.no_warnings()
    end)

    it("should repeat each global verb with dot when the verb is <leader>tx, <leader>tc, or <leader>tu", function()
        for index, case in ipairs({
            { keys = "<Space>tx", from = "- [ ] One", expect = "^%- %[x%] One$" },
            { keys = "<Space>tc", from = "- [ ] One", expect = "^%- %[x%] One ::complete" },
            { keys = "<Space>tu", from = "- [-] One ::irrelevant [[2026-02-17]] 10:00", expect = "^%- %[ %] One$" },
        }) do
            local second = case.from:gsub("One", "Two")
            open_source({ case.from, second }, "verb" .. index .. ".md")
            editor.input("gg" .. case.keys)
            editor.wait(
                "return vim.api.nvim_get_current_line():match(...) ~= nil",
                case.keys .. " not applied",
                case.expect
            )
            editor.input("j.")
            editor.wait(
                "return vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:match(...) ~= nil",
                case.keys .. " not repeated by dot",
                (case.expect:gsub("One", "Two"))
            )
            editor.no_warnings()
        end
    end)

    it("should warn and leave the line untouched when dot repeats onto a non-task line", function()
        open_source({ "- [ ] First", "Plain paragraph" })
        editor.input("<Space>ti")
        editor.wait("return vim.api.nvim_get_current_line():find('::irrelevant', 1, true) ~= nil", "first not marked")
        editor.input("j.")
        editor.wait("return #_G.test_warnings > 0", "non-task line was not reported")
        assert.are.equal("Plain paragraph", editor.lines()[2])
    end)

    it("should repeat <leader>ti in the task list and undo one task per u", function()
        vim.fn.writefile({ "- [ ] Alpha (@[[2026-02-17]])", "- [ ] Bravo (@[[2026-02-17]])" }, editor.path)
        editor.command("Tasks")
        ready_tasks("Bravo")
        editor.input("/Alpha<CR><Space>ti")
        wait_file(editor.path, function(lines)
            return lines[1]:find("::irrelevant", 1, true) ~= nil
        end, "Alpha not marked")
        editor.wait("return not require('taskbuffer.buffer').get_refreshing()", "task list did not refresh")
        local after_alpha = vim.fn.readfile(editor.path)
        editor.input("/Bravo<CR>.")
        wait_file(editor.path, function(lines)
            return lines[2]:find("::irrelevant", 1, true) ~= nil
        end, "dot did not repeat irrelevant in the task list")
        editor.wait("return not require('taskbuffer.buffer').get_refreshing()", "task list did not refresh")
        editor.input("u")
        wait_file(editor.path, function(lines)
            return vim.deep_equal(lines, after_alpha)
        end, "undo did not revert only Bravo")
        -- "/Bravo" may wrap around the list; that warning is not ours.
        editor.lua("vim.v.warningmsg = ''")
        editor.no_warnings()
    end)
end)
