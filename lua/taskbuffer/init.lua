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
