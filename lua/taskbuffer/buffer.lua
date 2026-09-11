local M = {}
local profile = require("taskbuffer.profile")

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

local active
local published = {}
local last_written
local directories = {}
local output_paths = {}
local cleanup_registered = false

local function list_opts(reuse)
    return {
        markers = show_markers,
        ignore_undated = not M.get_show_undated(),
        tags = vim.list_slice(active_tag_filter),
        reuse = reuse,
    }
end

local function taskfile_path()
    local base = require("taskbuffer.config").values.tmpdir
    if not directories[base] then
        local directory, err = vim.uv.fs_mkdtemp(base .. "/taskbuffer-XXXXXX")
        if not directory then
            return nil, err
        end
        directories[base] = directory
    end
    if not cleanup_registered then
        cleanup_registered = true
        vim.api.nvim_create_autocmd("VimLeavePre", {
            once = true,
            callback = function()
                for path in pairs(output_paths) do
                    vim.uv.fs_unlink(path)
                end
                for _, directory in pairs(directories) do
                    vim.uv.fs_rmdir(directory)
                end
            end,
        })
    end
    local path = directories[base] .. "/" .. os.date("%Y-%m-%d") .. ".taskfile"
    output_paths[path] = true
    return path
end

local function write_taskfile(text, path)
    if last_written and last_written.path == path and last_written.text == text then
        return true
    end
    local file, err = io.open(path, "w")
    if not file then
        return nil, err
    end
    local ok, failure = file:write(text)
    local closed, close_err = file:close()
    if not ok or not closed then
        return nil, failure or close_err
    end
    last_written = { path = path, text = text }
    return true
end
write_taskfile = profile.wrap("taskfile.write", write_taskfile)

-- Update only the requested buffer, preserving each window's cursor/view. No
-- edit! round trip, FileType replay, or touching the buffer the user moved to.
local function publish(buf, text, data)
    local previous = published[buf]
    if previous and previous.text == text and previous.tick == vim.api.nvim_buf_get_changedtick(buf) then
        previous.data = data
        return
    end
    local views = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    local modifiable = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.bo[buf].readonly = true
    vim.bo[buf].modifiable = modifiable
    published[buf] = { text = text, tick = vim.api.nvim_buf_get_changedtick(buf), data = data }
    for win, view in pairs(views) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(buf))
            vim.api.nvim_win_call(win, function()
                vim.fn.winrestview(view)
            end)
        end
    end
end
publish = profile.wrap("taskfile.publish", publish)

function M.validate_source(path, lnum)
    local snapshot = published[vim.api.nvim_get_current_buf()]
    local expected = snapshot and snapshot.data and snapshot.data.versions and snapshot.data.versions[path]
    local version = require("taskbuffer.source").version(path)
    local originals = snapshot and snapshot.data and snapshot.data.originals
    local original = originals and originals[path] and originals[path][lnum]
    local line_changed = original and require("taskbuffer.util").read_line_from_file(path, lnum) ~= original
    if
        refreshing
        or not expected
        or not version
        or line_changed
        or (expected ~= "true:" .. version and expected ~= "false:" .. version)
    then
        vim.notify(
            "[taskbuffer] task list is loading or stale; run :Tasks and retry after it refreshes",
            vim.log.levels.WARN
        )
        return false
    end
    return true
end

function M.cancel_refresh(buf)
    if active and (not buf or active.buf == buf) then
        if active.cancel then
            active.cancel()
        end
        profile.finish(active.span)
        active = nil
        refreshing = false
    end
end

function M.release(buf)
    M.cancel_refresh(buf)
    published[buf] = nil
end

-- Synchronous compatibility API for scripts only.
function M.refresh_taskfile()
    local text, err = require("taskbuffer.list").list(list_opts(false))
    if not err then
        local path
        path, err = taskfile_path()
        local ok
        if path then
            ok, err = write_taskfile(text or "", path)
        end
        if ok then
            return true
        end
    end
    vim.notify("[taskbuffer] task list failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
end

-- Coalesce identical pending requests; supersede changed views/source mutations.
-- The first require/scan is scheduled so opening an empty taskfile returns first.
function M.refresh_taskfile_async(callback, opts)
    opts = opts or {}
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local config = require("taskbuffer.config").values
    local runtime = list_opts(opts.reuse)
    runtime.force = opts.force
    if opts.force and package.loaded["taskbuffer.list"] then
        require("taskbuffer.list").invalidate()
    end
    local key = vim.json.encode({ runtime.markers, runtime.ignore_undated, runtime.tags })
    if active and active.buf == buf and active.key == key and active.config == config and not opts.force then
        if callback then
            active.callbacks[#active.callbacks + 1] = callback
        end
        return
    end
    M.cancel_refresh()
    local request = { buf = buf, key = key, config = config, callbacks = {} }
    if callback then
        request.callbacks[1] = callback
    end
    active = request
    refreshing = true
    local path, path_err = taskfile_path()
    local span = profile.begin("refresh.async.wall")
    request.span = span
    vim.schedule(function()
        if active ~= request then
            profile.finish(span)
            return
        end
        local function complete(text, err, data)
            if active ~= request then
                return
            end
            if not vim.api.nvim_buf_is_loaded(buf) then
                M.cancel_refresh(buf)
                return
            end
            local ok, failure = pcall(function()
                if err then
                    error(err, 0)
                end
                local written, write_err = write_taskfile(text or "", path)
                if not written then
                    error(write_err, 0)
                end
                publish(buf, text or "", data)
            end)
            active = nil
            refreshing = false
            profile.finish(span)
            if not ok then
                vim.notify("[taskbuffer] task list failed: " .. tostring(failure), vim.log.levels.ERROR)
            end
            for _, cb in ipairs(request.callbacks) do
                cb(ok and nil or failure)
            end
        end
        if not path then
            complete(nil, path_err)
            return
        end
        local ok, cancel = pcall(function()
            return require("taskbuffer.list").list_async(runtime, complete)
        end)
        if ok then
            request.cancel = cancel
        else
            complete(nil, cancel)
        end
    end)
end

function M.refresh_and_restore_cursor(callback)
    if vim.bo.filetype == "taskfile" then
        M.refresh_taskfile_async(callback, { force = true })
    end
end

-- Filters/markers affect only presentation, so reuse parsed source data.
function M.refresh_view()
    M.refresh_taskfile_async(nil, { reuse = true })
end

function M.setup_autocmds()
    require("taskbuffer.autocmds").register()
end

function M.tasks()
    M.clear_tag_filter()
    local path, err = taskfile_path()
    if not path then
        vim.notify("[taskbuffer] cannot create taskfile: " .. tostring(err), vim.log.levels.ERROR)
        return
    end
    if vim.api.nvim_buf_get_name(0) ~= path then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
    end
    vim.bo.readonly = true
    if vim.bo.filetype ~= "taskfile" then
        vim.bo.filetype = "taskfile"
    end
    M.refresh_taskfile_async()
end

function M.tasks_clear()
    M.clear_tag_filter()
    if vim.bo.filetype == "taskfile" then
        M.refresh_view()
    else
        M.tasks()
    end
    vim.notify("[taskbuffer] tag filter cleared", vim.log.levels.INFO)
end

M.refresh_taskfile = profile.wrap("refresh.sync", M.refresh_taskfile)
M.refresh_and_restore_cursor = profile.wrap("refresh.request", M.refresh_and_restore_cursor)
M.tasks = profile.wrap("tasks.command", M.tasks)
M.tasks_clear = profile.wrap("tasks_clear.command", M.tasks_clear)
return M
