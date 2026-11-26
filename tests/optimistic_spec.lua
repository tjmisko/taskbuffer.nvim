describe("optimistic task list actions", function()
    local editor

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

    local function drained()
        editor.wait("return require('taskbuffer.writer').idle()", "writer did not drain")
    end

    before_each(function()
        editor = require("tests.helpers.editor").new()
    end)

    after_each(function()
        if editor then
            pcall(vim.fn.setfperm, editor.root .. "/vault/locked", "rwxr-xr-x")
            editor.close()
            editor = nil
        end
    end)

    it("should mark every task irrelevant when dot is pressed 10+ times in one input", function()
        local first, second = {}, {}
        for index = 1, 12 do
            first[index] = ("- [ ] Alpha %02d (@[[2026-02-17]])"):format(index)
        end
        for index = 1, 5 do
            second[index] = ("- [ ] Beta %02d (@[[2026-02-18]])"):format(index)
        end
        local other = editor.root .. "/vault/beta.md"
        vim.fn.writefile(first, editor.path)
        vim.fn.writefile(second, other)
        editor.command("Tasks")
        ready_tasks("Alpha 12")
        editor.input("ggj<Space>ti" .. string.rep(".", 16))
        editor.wait(
            [[
            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            for _, line in ipairs(lines) do
                if line:find('Alpha', 1, true) or line:find('Beta', 1, true) then return false end
            end
            return true
        ]],
            "tasks stayed in the list"
        )
        drained()
        for _, target in ipairs({ editor.path, other }) do
            for _, line in ipairs(vim.fn.readfile(target)) do
                assert.is_truthy(line:find("- [-] ", 1, true), line)
                assert.is_truthy(line:find("::irrelevant", 1, true), line)
            end
        end
        assert.are.equal(12, #vim.fn.readfile(editor.path))
        assert.are.equal(5, #vim.fn.readfile(other))
        editor.no_warnings()
    end)

    it("should walk the cursor down the list when dot repeats on each removed row", function()
        local lines = {}
        for index = 1, 6 do
            lines[index] = ("- [ ] Task %d (@[[2026-02-17]])"):format(index)
        end
        vim.fn.writefile(lines, editor.path)
        editor.command("Tasks")
        ready_tasks("Task 6")
        editor.input("ggj<Space>ti" .. string.rep(".", 2))
        editor.wait(
            [[
            local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
            return not text:find('Task 1', 1, true) and not text:find('Task 3', 1, true)
                and text:find('Task 4', 1, true) ~= nil
        ]],
            "three tasks did not leave the list"
        )
        assert.is_truthy(editor.lua("return vim.api.nvim_get_current_line()"):find("Task 4", 1, true))
        drained()
        local disk = vim.fn.readfile(editor.path)
        for index = 1, 3 do
            assert.is_truthy(disk[index]:find("::irrelevant", 1, true))
        end
        assert.is_falsy(disk[4]:find("::irrelevant", 1, true))
        editor.no_warnings()
    end)

    it("should revert the row, drop the undo entry, and warn once when the write fails", function()
        local locked = editor.root .. "/vault/locked"
        vim.fn.mkdir(locked, "p")
        local fine = {}
        for index = 1, 3 do
            fine[index] = ("- [ ] Fine %d (@[[2026-02-17]])"):format(index)
        end
        vim.fn.writefile(fine, editor.path)
        vim.fn.writefile({ "- [ ] Locked task (@[[2026-02-18]])" }, locked .. "/locked.md")
        vim.fn.setfperm(locked, "r-xr-xr-x")
        local probe = io.open(locked .. "/probe", "w")
        if probe then
            probe:close()
            return pending("running with permission to write read-only directories")
        end
        editor.command("Tasks")
        ready_tasks("Locked task")
        editor.input("ggj<Space>ti" .. string.rep(".", 3))
        editor.wait(
            [[
            return #_G.test_warnings >= 1 and require('taskbuffer.writer').idle()
        ]],
            "the failed write was not reported"
        )
        ready_tasks("Locked task")
        drained()
        assert.are.equal(1, #editor.lua("return _G.test_warnings"))
        assert.is_truthy(editor.lua("return _G.test_warnings[1]"):find("locked.md", 1, true))
        for _, line in ipairs(vim.fn.readfile(editor.path)) do
            assert.is_truthy(line:find("::irrelevant", 1, true), line)
        end
        assert.are.same({ "- [ ] Locked task (@[[2026-02-18]])" }, vim.fn.readfile(locked .. "/locked.md"))
        assert.are.equal(3, editor.lua("return (require('taskbuffer.undo').depth())"))
        assert.is_truthy(table.concat(editor.lines(), "\n"):find("Locked task", 1, true))
    end)

    it("should land staged edits on disk when the editor quits right after an action", function()
        vim.fn.writefile({ "- [ ] Quick task (@[[2026-02-17]])" }, editor.path)
        editor.command("Tasks")
        ready_tasks("Quick task")
        editor.input("ggj<Space>ti")
        editor.wait(
            "return not table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), ''):find('Quick', 1, true)",
            "no action"
        )
        pcall(editor.command, "qa!")
        vim.wait(1000, function()
            return vim.fn.readfile(editor.path)[1]:find("::irrelevant", 1, true) ~= nil
        end, 10)
        assert.is_truthy(vim.fn.readfile(editor.path)[1]:find("::irrelevant", 1, true))
    end)
end)
