local M = {}

---@type string[]
local active_tag_filter = {}
local show_markers = false
---@type boolean|nil
local show_undated = nil
local refreshing = false

---@param tags string[]|nil
function M.set_tag_filter(tags)
    active_tag_filter = tags or {}
end

function M.clear_tag_filter()
    active_tag_filter = {}
end

---@return string[]
function M.get_tag_filter()
    return active_tag_filter
end

---@param val boolean
function M.set_refreshing(val)
    refreshing = val
end

---@return boolean
function M.get_refreshing()
    return refreshing
end

---@return boolean
function M.get_show_markers()
    return show_markers
end

---@param val boolean
function M.set_show_markers(val)
    show_markers = val
end

---@return boolean
function M.get_show_undated()
    if show_undated == nil then
        show_undated = require("taskbuffer.config").values.show_undated
    end
    return show_undated
end

---@param val boolean
function M.set_show_undated(val)
    show_undated = val
end

--- Refresh the taskfile, reload the buffer, and restore the cursor position.
function M.refresh_and_restore_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    M.set_refreshing(true)
    M.refresh_taskfile()
    vim.cmd("edit!")
    vim.bo.readonly = true
    M.set_refreshing(false)
    pcall(vim.api.nvim_win_set_cursor, 0, cursor)
end

--- Run the Go binary to regenerate the taskfile on disk.
function M.refresh_taskfile()
    local config = require("taskbuffer.config")
    local cfg = config.values
    local cmd = { cfg.task_bin }

    -- Pass source directories
    for _, arg in ipairs(config.source_args()) do
        table.insert(cmd, arg)
    end

    -- Pass config JSON
    table.insert(cmd, "--config")
    table.insert(cmd, config.config_json_arg())

    table.insert(cmd, "list")

    if show_markers then
        table.insert(cmd, "-markers")
    end
    if not M.get_show_undated() then
        table.insert(cmd, "--ignore-undated")
    end
    for _, tag in ipairs(active_tag_filter) do
        table.insert(cmd, "--tag")
        table.insert(cmd, tag)
    end

    local result = vim.system(cmd, { text = true }):wait()
    if result.code ~= 0 then
        vim.notify("[taskbuffer] task list failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
        return
    end

    local filepath = cfg.tmpdir .. "/" .. os.date("%Y-%m-%d") .. ".taskfile"
    local f, err = io.open(filepath, "w")
    if not f then
        vim.notify("[taskbuffer] failed to write taskfile: " .. err, vim.log.levels.ERROR)
        return
    end
    f:write(result.stdout)
    f:close()
end

--- Delegate to autocmds module for backward compat.
function M.setup_autocmds()
    require("taskbuffer.autocmds").register()
end

function M.tasks()
    M.clear_tag_filter()
    refreshing = true
    M.refresh_taskfile()
    local cfg = require("taskbuffer.config").values
    local filepath = cfg.tmpdir .. "/" .. vim.fn.strftime("%F") .. ".taskfile"
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
    vim.notify("[taskbuffer] tag filter cleared", vim.log.levels.INFO)
end

return M
