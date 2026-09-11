-- Invoked by benchmark.py, with an isolated generated vault and configuration.
local root = assert(vim.env.TASKBUFFER_BENCH_ROOT)
local dir = assert(vim.env.TASKBUFFER_BENCH_DIR)
local mode = assert(vim.env.TASKBUFFER_BENCH_MODE)
local config = {
    sources = { dir .. "/vault" },
    tmpdir = dir .. "/output",
    state_dir = dir .. "/state",
    inbox = { file = dir .. "/vault/inbox.md" },
}

if mode ~= "baseline" then
    vim.opt.rtp:prepend(root)
end

if mode ~= "workload" then
    if mode == "setup" then
        require("taskbuffer").setup(config)
    end
    -- Leave after VimEnter so --startuptime includes the complete startup.
    vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        callback = function()
            if mode ~= "baseline" then
                assert(vim.fn.exists(":TasksProfile") == 2, "plugin commands did not load")
                assert(not package.loaded["taskbuffer.scan"], "startup loaded the scan pipeline")
                assert(not package.loaded["taskbuffer.list"], "startup loaded the list pipeline")
                assert(not package.loaded["taskbuffer.keymaps"], "startup loaded keymap actions")
                assert(not package.loaded["taskbuffer.util"], "startup loaded task utilities")
            end
            vim.schedule(function()
                vim.cmd("qa!")
            end)
        end,
    })
    return
end

vim.cmd("filetype plugin on")
vim.cmd("syntax on")
vim.cmd("runtime plugin/taskbuffer.lua")
local profile = require("taskbuffer.profile")
local results = {}
local buffer

local function settle()
    assert(
        vim.wait(30000, function()
            return not buffer.get_refreshing()
        end, 5),
        "taskfile refresh timed out"
    )
    -- Give scheduled callbacks/the delay probe a turn after synchronous work.
    vim.wait(40, function()
        return false
    end, 5)
end

local function scenario(name, fn)
    profile.start()
    fn()
    profile.stop()
    results[name] = profile.snapshot()
end

scenario("setup", function()
    local tb = profile.measure("module.require", require, "taskbuffer")
    tb.setup(config)
end)
buffer = require("taskbuffer.buffer")

scenario("first_open", function()
    vim.cmd("Tasks")
    settle()
    assert(vim.bo.filetype == "taskfile", "taskfile did not open")
    assert(vim.api.nvim_buf_line_count(0) > 1, "taskfile is empty")
end)

local runs = assert(tonumber(vim.env.TASKBUFFER_BENCH_RUNS))
scenario("reopen", function()
    for _ = 1, runs do
        vim.cmd("enew!")
        vim.cmd("Tasks")
        settle()
    end
end)

scenario("bufenter", function()
    for _ = 1, runs do
        local taskfile = vim.api.nvim_get_current_buf()
        vim.cmd("enew!")
        vim.api.nvim_set_current_buf(taskfile)
        settle()
    end
end)

scenario("source_refresh", function()
    for _ = 1, runs do
        buffer.refresh_and_restore_cursor()
        settle()
    end
end)

scenario("view_changes", function()
    for _ = 1, runs do
        buffer.set_show_markers(not buffer.get_show_markers())
        buffer.refresh_view()
        settle()
    end
end)

scenario("tags", function()
    for _ = 1, runs do
        local done, failure = false, nil
        require("taskbuffer.list").tags_async({}, function(tags, err)
            failure = err
            assert(err or #tags > 0, "no tags found")
            done = true
        end)
        assert(
            vim.wait(30000, function()
                return done
            end, 5),
            "tag query timed out"
        )
        assert(not failure, failure)
        settle()
    end
end)

vim.fn.writefile({ vim.json.encode(results) }, dir .. "/workload.json")
vim.cmd("qa!")
