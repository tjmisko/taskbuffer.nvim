-- Invoked only by scripts/install-smoke.py with isolated XDG directories.
local root = assert(vim.env.TASKBUFFER_TEST_ROOT)
local mode = assert(vim.env.TASKBUFFER_TEST_MODE)
local project = vim.fn.getcwd()
local config = {
    sources = { root .. "/vault" },
    tmpdir = root,
    state_dir = root .. "/state/taskbuffer",
}
vim.fn.mkdir(config.sources[1], "p")
vim.fn.writefile({ "- [ ] Fresh install task #example" }, config.sources[1] .. "/tasks.md")

local function check()
    if mode == "native" then
        vim.opt.rtp:prepend(project)
        require("taskbuffer").setup(config)
        vim.cmd("runtime plugin/taskbuffer.lua")
    else
        vim.opt.rtp:prepend(assert(vim.env.TASKBUFFER_TEST_LAZY))
        require("lazy").setup({
            {
                dir = project,
                cmd = mode == "lazy-command" and { "Tasks", "TasksClear", "TasksUndated", "TasksProfile" } or nil,
                opts = config,
            },
        }, {
            checker = { enabled = false },
            change_detection = { enabled = false },
            lockfile = root .. "/lazy-lock.json",
        })
    end
    assert(not package.loaded["taskbuffer.scan"], "install eagerly loaded scan code")
    assert(not package.loaded["taskbuffer.source"], "install eagerly loaded mutation code")
    vim.cmd("Tasks")
    assert(
        vim.wait(5000, function()
            return not require("taskbuffer.buffer").get_refreshing()
        end, 10),
        "task refresh timed out"
    )
    assert(vim.bo.filetype == "taskfile", "missing filetype")
    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(content:find("Fresh install task", 1, true), "missing task")
    assert(type(vim.fn.maparg("gf", "n", false, true).callback) == "function", "missing navigation mapping")
    vim.cmd("TasksProfile report")
end

vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
        vim.schedule(function()
            local ok, err = xpcall(check, debug.traceback)
            if not ok then
                io.stderr:write(err .. "\n")
                vim.cmd("cquit 1")
            end
            vim.cmd("qa!")
        end)
    end,
})
