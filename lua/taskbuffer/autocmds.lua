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

    -- No global polling or source scans: refresh only while a taskfile is shown.
    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        pattern = "*taskfile",
        callback = function(event)
            local buffer = require("taskbuffer.buffer")
            buffer.prepare(event.buf)
            buffer.refresh_taskfile_async(nil, { buf = event.buf })
        end,
    })
    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
        group = augroup,
        pattern = "*taskfile",
        callback = function(event)
            local tags = package.loaded["taskbuffer.tags"]
            if tags then
                tags.cancel(event.buf)
            end
            local buffer = package.loaded["taskbuffer.buffer"]
            if buffer then
                if event.event == "BufHidden" then
                    buffer.cancel_refresh(event.buf)
                else
                    buffer.release(event.buf)
                end
            end
        end,
    })
end

return M
