local tb, buffer, dir, original_list
local requests
local original_notify

local function wait_for(count)
    assert.is_true(vim.wait(1000, function()
        return #requests == count
    end, 5))
end

local function text()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

describe("async taskfile buffers", function()
    before_each(function()
        local previous = package.loaded["taskbuffer.buffer"]
        if previous and previous.cancel_refresh then
            previous.cancel_refresh()
        end
        for _, name in ipairs({ "taskbuffer", "taskbuffer.config", "taskbuffer.buffer", "taskbuffer.keymaps" }) do
            package.loaded[name] = nil
        end
        tb = require("taskbuffer")
        buffer = require("taskbuffer.buffer")
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        tb.setup({ sources = { dir }, tmpdir = dir, state_dir = dir, inbox = { file = dir .. "/inbox.md" } })
        original_notify = vim.notify
        requests = {}
        original_list = package.loaded["taskbuffer.list"]
        package.loaded["taskbuffer.list"] = {
            invalidate = function() end,
            list_async = function(opts, cb)
                local request = { opts = opts, cb = cb, cancelled = false }
                requests[#requests + 1] = request
                return function()
                    request.cancelled = true
                end
            end,
        }
    end)

    after_each(function()
        vim.notify = original_notify
        buffer.cancel_refresh()
        vim.cmd("enew!")
        package.loaded["taskbuffer.list"] = original_list
        vim.fn.delete(dir, "rf")
    end)

    it("opens immediately and coalesces duplicate requests including BufEnter", function()
        buffer.tasks()
        assert.are.equal("taskfile", vim.bo.filetype)
        assert.is_true(buffer.get_refreshing())
        assert.are.equal(0, #requests) -- pipeline loading is deferred too
        buffer.tasks()
        buffer.tasks_clear()
        wait_for(1)
        requests[1].cb("# Today\nA task\n")
        assert.is_false(buffer.get_refreshing())
        assert.are.equal("# Today\nA task", text())
        assert.are.equal(1, #requests)
    end)

    it("cancels hidden buffers and ignores late results without touching the new buffer", function()
        buffer.tasks()
        wait_for(1)
        local path = vim.api.nvim_buf_get_name(0)
        vim.cmd("enew!")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved work" })
        assert.is_true(requests[1].cancelled)
        requests[1].cb("# Stale\nOld task\n")
        assert.are.equal("unsaved work", text())
        assert.is_true(vim.bo.modified)
        assert.is_false(vim.bo.readonly)
        assert.is_false(buffer.get_refreshing())
        assert.are.equal(0, vim.fn.filereadable(path))
    end)

    it("coalesces rapid filter changes and publishes only the latest result", function()
        buffer.tasks()
        wait_for(1)
        buffer.set_tag_filter({ "work" })
        buffer.refresh_view()
        buffer.set_tag_filter({ "personal" })
        buffer.refresh_view()
        wait_for(2)
        assert.is_true(requests[1].cancelled)
        assert.are.same({ "personal" }, requests[2].opts.tags)
        assert.is_true(requests[2].opts.reuse)
        requests[1].cb("stale\n")
        assert.is_true(buffer.get_refreshing())
        requests[2].cb("latest\n")
        assert.are.equal("latest", text())
        assert.is_false(buffer.get_refreshing())
    end)

    it("updates a taskfile visible in another window without stealing focus", function()
        buffer.tasks()
        wait_for(1)
        local task_buf = vim.api.nvim_get_current_buf()
        vim.cmd("vnew")
        local other_win = vim.api.nvim_get_current_win()
        local other_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "unsaved other window" })
        requests[1].cb("# Today\nPublished task\n")
        assert.are.equal(other_win, vim.api.nvim_get_current_win())
        assert.are.equal(other_buf, vim.api.nvim_get_current_buf())
        assert.are.equal("unsaved other window", text())
        assert.is_true(vim.bo.modified)
        assert.are.same({ "# Today", "Published task" }, vim.api.nvim_buf_get_lines(task_buf, 0, -1, false))
        vim.cmd("close!")
    end)

    it("keeps contents/cursor/changedtick intact when output did not change", function()
        buffer.tasks()
        wait_for(1)
        requests[1].cb("# Today\nA task\nAnother task\n")
        vim.api.nvim_win_set_cursor(0, { 2, 3 })
        local tick = vim.api.nvim_buf_get_changedtick(0)
        buffer.tasks()
        wait_for(2)
        requests[2].cb("# Today\nA task\nAnother task\n")
        assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(0))
        assert.are.same({ 2, 3 }, vim.api.nvim_win_get_cursor(0))
        assert.is_false(vim.bo.modified)
    end)

    it("recovers from scan and write failures without clearing existing output", function()
        buffer.tasks()
        wait_for(1)
        requests[1].cb("existing\n")
        local notify = vim.notify
        vim.notify = function() end
        buffer.refresh_and_restore_cursor()
        wait_for(2)
        requests[2].cb(nil, "scan failed")
        assert.is_false(buffer.get_refreshing())
        assert.are.equal("existing", text())
        -- A directory at the output filename exercises a write failure.
        local output = vim.api.nvim_buf_get_name(0)
        vim.fn.delete(output)
        vim.fn.mkdir(output)
        buffer.refresh_and_restore_cursor()
        wait_for(3)
        requests[3].cb("replacement\n")
        vim.notify = notify
        assert.is_false(buffer.get_refreshing())
        assert.are.equal("existing", text())
    end)

    it("refreshes source mutations asynchronously with a forced new snapshot", function()
        buffer.tasks()
        wait_for(1)
        local completed = false
        buffer.refresh_and_restore_cursor(function(err)
            assert.is_nil(err)
            completed = true
        end)
        wait_for(2)
        assert.is_true(requests[1].cancelled)
        assert.is_true(requests[2].opts.force)
        requests[2].cb("updated\n")
        assert.is_true(completed)
        assert.are.equal("updated", text())
    end)

    it("does no refresh work after an action outside a taskfile", function()
        buffer.refresh_and_restore_cursor()
        assert.is_false(buffer.get_refreshing())
        assert.are.equal(0, #requests)
    end)
end)
