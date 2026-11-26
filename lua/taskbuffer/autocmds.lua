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
        pattern = { "*.taskfile", "taskbuffer://*" },
        callback = discard_changes,
    })

    -- Staged edits live only in memory until the writer lands them.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = augroup,
        callback = function()
            local writer = package.loaded["taskbuffer.writer"]
            if writer then
                writer.flush_sync()
            end
        end,
    })

    -- Keep an existing index current without polling: reparse a saved note, and
    -- sweep for external changes when the editor regains focus.
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(event)
            local index = package.loaded["taskbuffer.index"]
            if not index or not index.is_ready() or event.file == "" then
                return
            end
            local path = vim.fn.fnamemodify(event.file, ":p")
            if index.accepts(path) then
                index.update_file_from_disk(path)
            end
        end,
    })
    vim.api.nvim_create_autocmd("FocusGained", {
        group = augroup,
        callback = function()
            local index = package.loaded["taskbuffer.index"]
            if not index or not index.is_ready() then
                return
            end
            local buffer = package.loaded["taskbuffer.buffer"]
            local visible = false
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                local buf = vim.api.nvim_win_get_buf(win)
                if buffer and vim.bo[buf].filetype == "taskfile" then
                    visible = true
                    buffer.refresh_taskfile_async(nil, { buf = buf })
                end
            end
            if not visible then
                index.refresh_async(
                    require("taskbuffer.context").build_context(require("taskbuffer.config").values),
                    function() end
                )
            end
        end,
    })

    -- No global polling or source scans: refresh only while a taskfile is shown.
    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        pattern = { "*.taskfile", "taskbuffer://*" },
        callback = function(event)
            local buffer = require("taskbuffer.buffer")
            buffer.prepare(event.buf)
            buffer.refresh_taskfile_async(nil, { buf = event.buf })
        end,
    })
    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
        group = augroup,
        pattern = { "*.taskfile", "taskbuffer://*" },
        callback = function(event)
            local tags = package.loaded["taskbuffer.tags"]
            if tags then
                tags.cancel(event.buf, event.event == "BufHidden")
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
