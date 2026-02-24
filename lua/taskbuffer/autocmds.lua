local M = {}

local autocmds_registered = false

local function discard_changes()
    if vim.bo.modified then
        vim.bo.modified = false
    end
end

function M.register()
    if autocmds_registered then
        return
    end
    autocmds_registered = true

    local augroup = vim.api.nvim_create_augroup("TaskBufferAutoCmd", { clear = true })

    -- Discard changes on buffer leave
    vim.api.nvim_create_autocmd({ "BufLeave", "QuitPre" }, {
        group = augroup,
        pattern = "*taskfile",
        callback = discard_changes,
    })

    -- Refresh on BufEnter
    vim.api.nvim_create_autocmd({ "BufEnter" }, {
        group = augroup,
        pattern = "*taskfile",
        callback = function()
            local buffer = require("taskbuffer.buffer")
            local buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_set_option_value("readonly", true, { buf = buf })
            if buffer.get_refreshing() then
                return
            end
            buffer.set_refreshing(true)
            buffer.refresh_taskfile()
            vim.cmd("edit!")
            buffer.set_refreshing(false)
            -- Reset cursor to beginning of line; conceal groups cause the
            -- restored column to land far past visible content.
            local row = vim.api.nvim_win_get_cursor(0)[1]
            vim.api.nvim_win_set_cursor(0, { row, 0 })
        end,
    })
end

return M
