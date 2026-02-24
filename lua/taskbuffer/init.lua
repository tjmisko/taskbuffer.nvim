if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("[taskbuffer] requires Neovim >= 0.10", vim.log.levels.ERROR)
    return {}
end

local M = {}

local config = require("taskbuffer.config")

--- Alias for backward compatibility; points to the live config values.
M.config = config.values

--- Delegate to config module.
M.source_args = config.source_args
M.config_json_arg = config.config_json_arg

function M.setup(opts)
    config.apply(opts)
    M.config = config.values

    require("taskbuffer.autocmds").register()
    require("taskbuffer.keymaps").setup_keymaps()
end

function M.tasks()
    require("taskbuffer.autocmds").register()
    require("taskbuffer.keymaps").setup_keymaps()
    require("taskbuffer.buffer").tasks()
end

function M.tasks_clear()
    require("taskbuffer.autocmds").register()
    require("taskbuffer.keymaps").setup_keymaps()
    require("taskbuffer.buffer").tasks_clear()
end

return M
