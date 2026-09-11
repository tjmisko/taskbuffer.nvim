describe("startup performance contract", function()
    for _, recording in ipairs({ false, true }) do
        it("keeps the task pipeline unloaded with profiling " .. tostring(recording), function()
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
            local script = dir .. "/startup.lua"
            local root = vim.fn.getcwd()
            local code = string.format(
                [[
vim.opt.rtp:prepend(%q)
vim.g.taskbuffer_profile = %s
vim.cmd("runtime plugin/taskbuffer.lua")
assert(vim.fn.exists(":Tasks") == 2)
assert(vim.fn.exists(":TasksProfile") == 2)
assert(not package.loaded["taskbuffer"])
assert(not package.loaded["taskbuffer.profile"])
vim.system = function() error("startup must not launch a subprocess") end
local dir = %q
local open = io.open
io.open = function() error("setup must not read or write files") end
local stat = vim.uv.fs_stat
vim.uv.fs_stat = function() error("setup must not stat files") end
require("taskbuffer").setup({
    sources = { dir }, tmpdir = dir, state_dir = dir,
    inbox = { file = dir .. "/inbox.md" },
})
for _, name in ipairs({ "scan", "list", "parse", "frontmatter", "buffer", "tags", "keymaps", "util", "async", "source" }) do
    assert(not package.loaded["taskbuffer." .. name], "eagerly loaded " .. name)
end
vim.bo.filetype = "markdown"
assert(not package.loaded["taskbuffer.keymaps"], "opening markdown loaded keymap actions")
assert(not package.loaded["taskbuffer.util"], "opening markdown loaded task utilities")
io.open = open
vim.uv.fs_stat = stat
local profile = require("taskbuffer.profile")
assert(profile.snapshot().enabled == %s)
if %s then
    local found = false
    for _, row in ipairs(profile.snapshot().stages) do
        if row.name == "setup" then found = true end
    end
    assert(found, "setup was not recorded")
else
    assert(#profile.snapshot().stages == 0)
end
vim.cmd("TasksProfile stop")
assert(not profile.snapshot().enabled)
vim.cmd("TasksProfile start")
assert(profile.snapshot().enabled)
vim.cmd("TasksProfile reset")
assert(#profile.snapshot().stages == 0)
vim.cmd("TasksProfile stop")
vim.cmd("qa!")
]],
                root,
                tostring(recording),
                dir,
                tostring(recording),
                tostring(recording)
            )
            vim.fn.writefile(vim.split(code, "\n", { plain = true }), script)
            local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script }, {
                text = true,
                env = {
                    XDG_CONFIG_HOME = dir .. "/config",
                    XDG_DATA_HOME = dir .. "/data",
                    XDG_STATE_HOME = dir .. "/state",
                    XDG_CACHE_HOME = dir .. "/cache",
                    NVIM_LOG_FILE = dir .. "/nvim.log",
                },
            }):wait(10000)
            vim.fn.delete(dir, "rf")
            assert.are.equal(0, result.code, result.stderr)
        end)
    end
end)
