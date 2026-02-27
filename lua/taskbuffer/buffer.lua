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

--- Refresh the taskfile and restore the cursor to its previous position.
function M.refresh_and_restore_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    M.set_refreshing(true)
    M.refresh_taskfile()
    vim.cmd("edit!")
    vim.bo.readonly = true
    M.set_refreshing(false)
    pcall(vim.api.nvim_win_set_cursor, 0, cursor)
end

--- Build the command table for the Go CLI binary.
---@return string[]
local function build_cmd()
    local config = require("taskbuffer.config")
    local cfg = config.values
    local cmd = { cfg.task_bin }
    for _, arg in ipairs(config.source_args()) do
        table.insert(cmd, arg)
    end
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
    return cmd
end

--- Write stdout content to the taskfile on disk.
---@param stdout string
---@return boolean
local function write_taskfile(stdout)
    local cfg = require("taskbuffer.config").values
    local filepath = cfg.tmpdir .. "/" .. os.date("%Y-%m-%d") .. ".taskfile"
    local f, err = io.open(filepath, "w")
    if not f then
        vim.notify("[taskbuffer] failed to write taskfile: " .. err, vim.log.levels.ERROR)
        return false
    end
    f:write(stdout)
    f:close()
    return true
end

--- Run the Go binary synchronously to regenerate the taskfile on disk.
function M.refresh_taskfile()
    local cmd = build_cmd()
    local result = vim.system(cmd, { text = true }):wait()
    if result.code ~= 0 then
        vim.notify("[taskbuffer] task list failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
        return
    end
    write_taskfile(result.stdout)
end

--- Run the Go binary asynchronously and invoke callback on completion.
---@param callback fun()
function M.refresh_taskfile_async(callback)
    local cmd = build_cmd()
    vim.system(cmd, { text = true }, function(result)
        if result.code ~= 0 then
            vim.schedule(function()
                vim.notify("[taskbuffer] task list failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
                refreshing = false
            end)
            return
        end
        vim.schedule(function()
            write_taskfile(result.stdout)
            callback()
        end)
    end)
end

--- Delegate to autocmds module for backward compat.
function M.setup_autocmds()
    require("taskbuffer.autocmds").register()
end

function M.tasks()
    M.clear_tag_filter()
    local cfg = require("taskbuffer.config").values
    local filepath = cfg.tmpdir .. "/" .. vim.fn.strftime("%F") .. ".taskfile"
    if vim.uv.fs_stat(filepath) then
        vim.cmd("edit! " .. filepath)
        vim.bo.readonly = true
        refreshing = true
        M.refresh_taskfile_async(function()
            vim.cmd("edit!")
            vim.bo.readonly = true
            refreshing = false
        end)
    else
        refreshing = true
        M.refresh_taskfile()
        vim.cmd("edit! " .. filepath)
        vim.bo.readonly = true
        refreshing = false
    end
end

function M.tasks_clear()
    M.clear_tag_filter()
    local cfg = require("taskbuffer.config").values
    local filepath = cfg.tmpdir .. "/" .. vim.fn.strftime("%F") .. ".taskfile"
    if vim.uv.fs_stat(filepath) then
        vim.cmd("edit!")
        vim.bo.readonly = true
        refreshing = true
        M.refresh_taskfile_async(function()
            vim.cmd("edit!")
            vim.bo.readonly = true
            refreshing = false
        end)
    else
        refreshing = true
        M.refresh_taskfile()
        vim.cmd("edit! " .. filepath)
        vim.bo.readonly = true
        refreshing = false
    end
    vim.notify("[taskbuffer] tag filter cleared", vim.log.levels.INFO)
end

return M
