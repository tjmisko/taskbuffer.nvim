local config = require("taskbuffer.config")

local dir, buffer, index, source
local real_time = os.time

local function lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function text()
    return table.concat(lines(), "\n")
end

local function open_tasks()
    buffer.tasks()
    assert.is_true(vim.wait(10000, function()
        return not buffer.get_refreshing() and #lines() > 1
    end, 5))
end

local function setup_vault(files)
    for name, content in pairs(files) do
        vim.fn.writefile(content, dir .. "/" .. name)
    end
    config.apply({ sources = { dir }, tmpdir = dir, state_dir = dir, inbox = { file = dir .. "/inbox.md" } })
    index.reset()
end

describe("incremental list rendering", function()
    before_each(function()
        buffer = require("taskbuffer.buffer")
        index = require("taskbuffer.index")
        source = require("taskbuffer.source")
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        vim.cmd("enew!")
    end)

    after_each(function()
        os.time = real_time
        require("taskbuffer.writer").flush_sync()
        local buf = vim.api.nvim_get_current_buf()
        vim.cmd("enew!")
        pcall(buffer.release, buf)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        index.reset()
        vim.fn.delete(dir, "rf")
    end)

    it("should publish a local change by replacing only the changed rows", function()
        local entries = {}
        for number = 1, 30 do
            entries[number] = ("- [ ] Task %02d (@[[2026-02-%02d]])"):format(number, number % 20 + 1)
        end
        setup_vault({ ["a.md"] = entries })
        open_tasks()
        local before = lines()
        local changes = {}
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_attach(buf, false, {
            on_lines = function(_, _, _, first, last_old, last_new)
                changes[#changes + 1] = { first, last_old, last_new }
            end,
        })
        local row
        for number, line in ipairs(before) do
            if line:find("Task 15", 1, true) then
                row = number
            end
        end
        local path = dir .. "/a.md"
        local data = source.read(path)
        local rewritten = data:gsub("%- %[ %] Task 15", "- [x] Task 15", 1)
        assert.is_true(source.write(path, rewritten))
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        buffer.apply_local_change()
        local after = lines()
        assert.are.equal(#before - 1, #after)
        assert.is_nil(text():find("Task 15", 1, true))
        assert.are.equal(1, #changes)
        assert.are.equal(row - 1, changes[1][1])
        assert.are.equal(row, changes[1][2])
        assert.are.equal(row - 1, changes[1][3])
    end)

    it("should publish a local change within 15 ms at 10k tasks in 10k files", function()
        local files = {}
        -- Many small files: the shape where per-file index cost dominates.
        for file = 1, 10000 do
            files[("d%02d/n%05d.md"):format(file % 50, file)] = {
                ("- [ ] Task %d-1 (@[[2026-02-%02d]]) #t%d"):format(file, (file % 27) + 1, file % 7),
            }
        end
        for dirnum = 0, 49 do
            vim.fn.mkdir(("%s/d%02d"):format(dir, dirnum), "p")
        end
        local entries = {}
        for number = 1, 5 do
            entries[number] = ("- [ ] Probe %d (@[[2026-02-10]])"):format(number)
        end
        files["n050.md"] = entries
        setup_vault(files)
        open_tasks()
        assert.is_true(#lines() > 9000)
        local path = dir .. "/n050.md"
        local samples = {}
        for round = 1, 5 do
            local data = source.read(path)
            local rewritten = data:gsub("%- %[ %] Probe " .. round .. " ", "- [x] Probe " .. round .. " ", 1)
            assert.is_true(source.write(path, rewritten))
            local started = vim.uv.hrtime()
            buffer.apply_local_change()
            samples[#samples + 1] = (vim.uv.hrtime() - started) / 1e6
            assert.is_nil(text():find("Probe " .. round .. " ", 1, true))
        end
        table.sort(samples)
        assert.is_true(samples[3] < 15, "median local publish took " .. samples[3] .. " ms")
    end)

    it("should move a Today task to Overdue at midnight without reading disk", function()
        local today = os.date("%Y-%m-%d", real_time())
        setup_vault({ ["a.md"] = { "- [ ] Rolling task (@[[" .. today .. "]])" } })
        open_tasks()
        assert.are.equal("# Today", lines()[1])
        local reads = 0
        local originals = {}
        for _, name in ipairs({ "fs_open", "fs_stat", "fs_scandir", "fs_lstat", "fs_readlink" }) do
            originals[name] = vim.uv[name]
            vim.uv[name] = function(...)
                reads = reads + 1
                return originals[name](...)
            end
        end
        local real_open = io.open
        io.open = function(...)
            reads = reads + 1
            return real_open(...)
        end
        os.time = function(arg)
            if arg then
                return real_time(arg)
            end
            return real_time() + 86400
        end
        buffer.rollover()
        local rolled = vim.wait(5000, function()
            return lines()[1] == "# Overdue"
        end, 5)
        vim.wait(30, function()
            return false
        end, 5)
        for name, original in pairs(originals) do
            vim.uv[name] = original
        end
        io.open = real_open
        assert.is_true(rolled, text())
        assert.is_truthy(text():find("Rolling task", 1, true))
        assert.are.equal(0, reads)
    end)

    it("should compute the delay until the next local midnight", function()
        local noon = real_time({ year = 2026, month = 2, day = 17, hour = 12 })
        assert.are.equal(12 * 3600 * 1000 + 1000, buffer.ms_until_midnight(noon))
        local late = real_time({ year = 2026, month = 12, day = 31, hour = 23, min = 59, sec = 59 })
        assert.is_true(buffer.ms_until_midnight(late) <= 2000)
        assert.is_true(buffer.ms_until_midnight(late) >= 1000)
    end)

    it("should stop the rollover timer when the last task list is released", function()
        setup_vault({ ["a.md"] = { "- [ ] One (@[[2026-02-17]])" } })
        open_tasks()
        local buf = vim.api.nvim_get_current_buf()
        vim.cmd("enew!")
        buffer.release(buf)
        assert.is_false(buffer.rollover_armed())
    end)
end)
