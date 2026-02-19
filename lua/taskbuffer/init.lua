local M = {}

-- Auto-detect plugin root from this file's location
local script_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(script_path, ":h:h:h")

M.config = {
    task_bin = plugin_root .. "/go/task_bin",
    notes_dir = vim.fn.expand("~/Documents/Notes"),
    state_dir = vim.fn.expand("~/.local/state/task"),
    tmpdir = "/tmp",
}

function M.setup(opts)
    opts = opts or {}
    for k, v in pairs(opts) do
        if M.config[k] ~= nil then
            M.config[k] = vim.fn.expand(v)
        end
    end
    require("taskbuffer.buffer").setup_autocmds()
    require("taskbuffer.keymaps").setup_keymaps()
end

function M.tasks()
    require("taskbuffer.buffer").setup_autocmds()
    require("taskbuffer.keymaps").setup_keymaps()
    require("taskbuffer.buffer").tasks()
end

function M.tasks_clear()
    require("taskbuffer.buffer").setup_autocmds()
    require("taskbuffer.keymaps").setup_keymaps()
    require("taskbuffer.buffer").tasks_clear()
end

return M
