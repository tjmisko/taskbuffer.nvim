local M = {}

local active_tag_filter = {}
local show_markers = false
local refreshing = false
local autocmds_registered = false

local augroup = vim.api.nvim_create_augroup("TaskBufferAutoCmd", { clear = true })

function M.set_tag_filter(tags)
    active_tag_filter = tags or {}
end

function M.clear_tag_filter()
    active_tag_filter = {}
end

function M.get_tag_filter()
    return active_tag_filter
end

function M.set_refreshing(val)
    refreshing = val
end

function M.get_show_markers()
    return show_markers
end

function M.set_show_markers(val)
    show_markers = val
end

function M.refresh_taskfile()
    local tb = require("taskbuffer")
    local config = tb.config
    local cmd = { config.task_bin }

    -- Pass source directories
    for _, arg in ipairs(tb.source_args()) do
        table.insert(cmd, arg)
    end

    -- Pass config JSON
    table.insert(cmd, "--config")
    table.insert(cmd, tb.config_json_arg())

    table.insert(cmd, "list")

    if show_markers then
        table.insert(cmd, "-markers")
    end
    for _, tag in ipairs(active_tag_filter) do
        table.insert(cmd, "--tag")
        table.insert(cmd, tag)
    end

    local result = vim.system(cmd, { text = true }):wait()
    if result.code ~= 0 then
        vim.notify("task list failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
        return
    end

    local filepath = config.tmpdir .. "/" .. os.date("%Y-%m-%d") .. ".taskfile"
    local f = assert(io.open(filepath, "w"))
    f:write(result.stdout)
    f:close()
end

local function discard_changes()
    if vim.bo.modified then
        vim.bo.modified = false
    end
end

function M.setup_autocmds()
    if autocmds_registered then
        return
    end
    autocmds_registered = true

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
            local buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_set_option_value("readonly", true, { buf = buf })
            if refreshing then
                return
            end
            refreshing = true
            M.refresh_taskfile()
            vim.cmd("edit!")
            refreshing = false
        end,
    })
end

function M.tasks()
    M.clear_tag_filter()
    refreshing = true
    M.refresh_taskfile()
    local config = require("taskbuffer").config
    local filepath = config.tmpdir .. "/" .. vim.fn.strftime("%F") .. ".taskfile"
    vim.cmd("edit! " .. filepath)
    vim.bo.readonly = true
    refreshing = false
end

function M.tasks_clear()
    M.clear_tag_filter()
    refreshing = true
    M.refresh_taskfile()
    vim.cmd("edit!")
    vim.bo.readonly = true
    refreshing = false
    vim.notify("Tag filter cleared", vim.log.levels.INFO)
end

return M
