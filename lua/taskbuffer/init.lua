if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("[taskbuffer] requires Neovim >= 0.10", vim.log.levels.ERROR)
    return {}
end

local M = {}

local profile = require("taskbuffer.profile")
local config = require("taskbuffer.config")

--- Alias for backward compatibility; points to the live config values.
M.config = config.values

--- Delegate to config module.
M.source_args = config.source_args
M.config_json_arg = config.config_json_arg

function M.setup(opts)
    profile.measure("setup.config", config.apply, opts)
    M.config = config.values
    local buffer = package.loaded["taskbuffer.buffer"]
    if buffer and buffer.cancel_refresh then
        buffer.cancel_refresh()
    end
    local list = package.loaded["taskbuffer.list"]
    if list then
        list.invalidate()
    end

    profile.measure("setup.entrypoints", function()
        require("taskbuffer.bootstrap").register()
    end)
end

function M.tasks()
    require("taskbuffer.bootstrap").register()
    require("taskbuffer.buffer").tasks()
end

function M.tasks_clear()
    require("taskbuffer.bootstrap").register()
    require("taskbuffer.buffer").tasks_clear()
end

M.setup = profile.wrap("setup", M.setup)

return M
