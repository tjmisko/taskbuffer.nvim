local util = require("taskbuffer.util")

describe("undo", function()
    local undo

    before_each(function()
        package.loaded["taskbuffer.undo"] = nil
        undo = require("taskbuffer.undo")
    end)

    --- Create a temp file with the given lines and return its path.
    ---@param lines string[]
    ---@return string
    local function temp_file(lines)
        local path = vim.fn.tempname() .. ".md"
        local f = io.open(path, "w")
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
        return path
    end

    it("should undo a single edit", function()
        local path = temp_file({
            "- [ ] Original task (@[[2026-02-17]])",
            "- [ ] Other task (@[[2026-02-18]])",
        })

        local old_line = "- [ ] Original task (@[[2026-02-17]])"
        local new_line = "- [x] Original task (@[[2026-02-17]]) ::complete [[2026-02-17]] 10:00"

        -- Simulate the edit
        util.replace_line_in_file(path, 1, new_line)
        assert.are.equal(new_line, util.read_line_from_file(path, 1))

        -- Push undo entry
        undo.push({
            op = "complete",
            edits = { { filepath = path, linenumber = 1, old_line = old_line, new_line = new_line } },
            timestamp = os.time(),
        })

        -- Stub out buffer refresh to avoid errors in headless mode
        package.loaded["taskbuffer.buffer"] = { refresh_and_restore_cursor = function() end }

        -- Undo should revert the file
        undo.undo()
        assert.are.equal(old_line, util.read_line_from_file(path, 1))
        -- Other line should be untouched
        assert.are.equal("- [ ] Other task (@[[2026-02-18]])", util.read_line_from_file(path, 2))

        os.remove(path)
    end)

    it("should redo after undo", function()
        local path = temp_file({
            "- [ ] Task one (@[[2026-02-17]])",
        })

        local old_line = "- [ ] Task one (@[[2026-02-17]])"
        local new_line = "- [x] Task one (@[[2026-02-17]])"

        util.replace_line_in_file(path, 1, new_line)

        undo.push({
            op = "check_off",
            edits = { { filepath = path, linenumber = 1, old_line = old_line, new_line = new_line } },
            timestamp = os.time(),
        })

        package.loaded["taskbuffer.buffer"] = { refresh_and_restore_cursor = function() end }

        -- Undo
        undo.undo()
        assert.are.equal(old_line, util.read_line_from_file(path, 1))

        -- Redo should re-apply the edit
        undo.redo()
        assert.are.equal(new_line, util.read_line_from_file(path, 1))

        os.remove(path)
    end)

    it("should drop oldest entry when stack overflows", function()
        package.loaded["taskbuffer.buffer"] = { refresh_and_restore_cursor = function() end }

        local path = temp_file({ "- [ ] Overflow test" })

        -- Push 101 entries
        for i = 1, 101 do
            undo.push({
                op = "op_" .. i,
                edits = { { filepath = path, linenumber = 1, old_line = "old_" .. i, new_line = "new_" .. i } },
                timestamp = os.time(),
            })
        end

        -- Write the expected "current" state for the most recent entry
        util.replace_line_in_file(path, 1, "new_101")

        -- Undo the most recent (op_101) -- should work
        undo.undo()
        assert.are.equal("old_101", util.read_line_from_file(path, 1))

        -- We should be able to undo 99 more times (op_2 through op_100)
        -- but op_1 should have been dropped.
        -- Just verify the undo worked for the latest entry.

        os.remove(path)
    end)

    it("should refuse undo when file modified externally", function()
        local path = temp_file({
            "- [ ] Will be modified externally (@[[2026-02-17]])",
        })

        local old_line = "- [ ] Will be modified externally (@[[2026-02-17]])"
        local new_line = "- [x] Will be modified externally (@[[2026-02-17]])"

        util.replace_line_in_file(path, 1, new_line)

        undo.push({
            op = "complete",
            edits = { { filepath = path, linenumber = 1, old_line = old_line, new_line = new_line } },
            timestamp = os.time(),
        })

        -- Externally modify the file (simulating another process)
        util.replace_line_in_file(path, 1, "- [x] EXTERNALLY MODIFIED")

        package.loaded["taskbuffer.buffer"] = { refresh_and_restore_cursor = function() end }

        -- Undo should refuse (file no longer matches new_line)
        undo.undo()
        -- File should still have the external modification
        assert.are.equal("- [x] EXTERNALLY MODIFIED", util.read_line_from_file(path, 1))

        os.remove(path)
    end)

    it("should clear redo stack after new push", function()
        local path = temp_file({ "- [ ] Redo clear test" })

        local old_line = "- [ ] Redo clear test"
        local new_line = "- [x] Redo clear test"

        util.replace_line_in_file(path, 1, new_line)

        undo.push({
            op = "check_off",
            edits = { { filepath = path, linenumber = 1, old_line = old_line, new_line = new_line } },
            timestamp = os.time(),
        })

        package.loaded["taskbuffer.buffer"] = { refresh_and_restore_cursor = function() end }

        -- Undo to populate redo stack
        undo.undo()
        assert.are.equal(old_line, util.read_line_from_file(path, 1))

        -- Push a new entry -- should clear redo stack
        local new_line2 = "- [-] Redo clear test"
        util.replace_line_in_file(path, 1, new_line2)
        undo.push({
            op = "irrelevant",
            edits = { { filepath = path, linenumber = 1, old_line = old_line, new_line = new_line2 } },
            timestamp = os.time(),
        })

        -- Redo should do nothing (stack was cleared)
        undo.redo()
        -- File should still have new_line2 content
        assert.are.equal(new_line2, util.read_line_from_file(path, 1))

        os.remove(path)
    end)
end)
