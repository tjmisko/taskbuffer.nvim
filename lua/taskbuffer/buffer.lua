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
local view_name = "taskbuffer://tasks"
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
        -- Neovim resolves directory symlinks in buffer names (notably /var on
        -- macOS). Compare the same canonical spelling to avoid an edit! reload.
        directories[base] = vim.uv.fs_realpath(directory) or directory
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
local function task_key(task)
    return task and task.file_path .. "\0" .. task.line_number or nil
end

-- Replace only the span between the common head and tail of the old and new
-- text. Falls back to the whole buffer when the old text is not known to be
-- what the buffer holds (someone else edited it).
local function replace_changed_range(buf, previous, lines)
    if not previous or previous.tick ~= vim.api.nvim_buf_get_changedtick(buf) then
        return vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
    local old = previous.lines
    local shared = math.min(#old, #lines)
    local head = 0
    while head < shared and old[head + 1] == lines[head + 1] do
        head = head + 1
    end
    local tail = 0
    while tail < shared - head and old[#old - tail] == lines[#lines - tail] do
        tail = tail + 1
    end
    local replacement = vim.list_slice(lines, head + 1, #lines - tail)
    return vim.api.nvim_buf_set_lines(buf, head, #old - tail, false, replacement)
end

local rollover_timer

-- Milliseconds from `now` (epoch seconds) to the next local midnight.
function M.ms_until_midnight(now)
    local date = os.date("*t", now)
    local midnight = os.time({ year = date.year, month = date.month, day = date.day + 1, hour = 0, min = 0, sec = 0 })
    -- One second of slack so the re-render resolves the new day.
    return math.max(1000, (midnight - now) * 1000 + 1000)
end

local function stop_rollover_timer()
    if rollover_timer and not rollover_timer:is_closing() then
        rollover_timer:stop()
        rollover_timer:close()
    end
    rollover_timer = nil
end

-- Re-render every shown task list from the index, so Today/Overdue buckets
-- follow the calendar. Reads no files: the index is reused as it is.
function M.rollover()
    stop_rollover_timer()
    for buf in pairs(published) do
        if vim.api.nvim_buf_is_loaded(buf) then
            M.refresh_taskfile_async(nil, { buf = buf, reuse = true })
        end
    end
    M.start_rollover_timer()
end

function M.rollover_armed()
    return rollover_timer ~= nil
end

-- Armed only while a task list snapshot exists; one timer for all lists.
function M.start_rollover_timer()
    if rollover_timer or next(published) == nil then
        return
    end
    rollover_timer = vim.uv.new_timer()
    rollover_timer:start(
        math.min(M.ms_until_midnight(os.time()), 2 ^ 31 - 1),
        0,
        vim.schedule_wrap(function()
            M.rollover()
        end)
    )
end

local function publish(buf, view, data)
    local previous = published[buf]
    local lines = #view.lines > 0 and view.lines or { "" }
    local unchanged = previous
        and previous.tick == vim.api.nvim_buf_get_changedtick(buf)
        and vim.deep_equal(previous.lines, lines)
    local views, selected, locations = {}, {}, {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
        selected[win] = previous and task_key(previous.rows[views[win].lnum])
        if selected[win] then
            locations[selected[win]] = {}
        end
    end
    if next(locations) then
        for row, task in pairs(view.rows) do
            local key = task_key(task)
            if locations[key] then
                table.insert(locations[key], row)
            end
        end
    end
    if not unchanged then
        -- Buffer observers may run inside set_lines; expose no stale row map.
        published[buf] = nil
        vim.bo[buf].modifiable = true
        vim.bo[buf].readonly = false
        local ok, err = pcall(replace_changed_range, buf, previous, lines)
        vim.bo[buf].modified = false
        vim.bo[buf].readonly = true
        vim.bo[buf].modifiable = false
        if not ok then
            published[buf] = previous
            error(err)
        end
    end
    -- Replace the complete snapshot even if identical text refers to new tasks.
    -- No yielding between the text update and publishing its row associations.
    published[buf] = { lines = lines, rows = view.rows, tick = vim.api.nvim_buf_get_changedtick(buf), data = data }
    M.start_rollover_timer()
    for win, saved in pairs(views) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            local row, distance = nil, math.huge
            for _, candidate in ipairs(locations[selected[win]] or {}) do
                if math.abs(candidate - saved.lnum) < distance then
                    row, distance = candidate, math.abs(candidate - saved.lnum)
                end
            end
            if row then
                saved.topline = math.max(1, saved.topline + row - saved.lnum)
                saved.lnum = row
            else
                saved.lnum = math.min(saved.lnum, #lines)
            end
            vim.api.nvim_win_call(win, function()
                vim.fn.winrestview(saved)
            end)
        end
    end
end
publish = profile.wrap("taskfile.publish", publish)

-- Row numbers belong to this rendered snapshot, never to hidden buffer text.
function M.task_at(row, buf)
    buf = buf and buf ~= 0 and buf or vim.api.nvim_get_current_buf()
    local snapshot = published[buf]
    if not snapshot or snapshot.tick ~= vim.api.nvim_buf_get_changedtick(buf) then
        return nil
    end
    row = row or vim.api.nvim_win_get_cursor(0)[1]
    return snapshot.rows[row]
end

function M.tasks_in_rows(rows)
    local tasks, seen = {}, {}
    for _, row in ipairs(rows) do
        local task = M.task_at(row)
        local key = task_key(task)
        if key and not seen[key] then
            tasks[#tasks + 1] = task
            seen[key] = true
        end
    end
    return tasks, published[vim.api.nvim_get_current_buf()]
end

function M.selection_is_current(snapshot)
    local buf = vim.api.nvim_get_current_buf()
    return snapshot ~= nil and snapshot == published[buf] and snapshot.tick == vim.api.nvim_buf_get_changedtick(buf)
end

-- An action changed the index. Render it now, in the keypress, so a typed-ahead
-- key sees the new rows. The cursor follows its task if it is still listed;
-- otherwise it keeps its row number (clamped), which lands on the next task.
function M.apply_local_change(callback)
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "taskfile" then
        if callback then
            callback(nil)
        end
        return
    end
    -- A refresh already in flight would publish rows from before this change.
    local superseded = active ~= nil
    M.cancel_refresh()
    local view, err, data = require("taskbuffer.list").view_sync(list_opts(true))
    local ok, failure = true, err
    if not err then
        ok, failure = pcall(publish, buf, view, data)
        failure = not ok and failure or nil
    end
    if failure then
        vim.notify("[taskbuffer] task list failed: " .. tostring(failure), vim.log.levels.ERROR)
    elseif superseded then
        M.refresh_taskfile_async(nil, { buf = buf })
    end
    if callback then
        callback(failure)
    end
end

function M.validate_source(path, lnum)
    local snapshot = published[vim.api.nvim_get_current_buf()]
    local annotations = snapshot and snapshot.data and snapshot.data.annotations
    if annotations and annotations[path] and annotations[path][lnum] then
        vim.notify("[taskbuffer] edit the code annotation in its source (Enter or gf)", vim.log.levels.WARN)
        return false
    end
    local known = snapshot and snapshot.data and snapshot.data.versions and snapshot.data.versions[path]
    local originals = snapshot and snapshot.data and snapshot.data.originals
    local original = originals and originals[path] and originals[path][lnum]
    -- The row must still describe the source line, as the user would see it:
    -- the overlay already holds our own unsaved edits.
    local line_changed = original and require("taskbuffer.util").read_line_from_file(path, lnum) ~= original
    if not snapshot or snapshot.tick ~= vim.api.nvim_buf_get_changedtick(0) or not known or line_changed then
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
    if next(published) == nil then
        stop_rollover_timer()
    end
end

-- The interactive view lives only in memory. Its task data lives in Lua.
function M.prepare(buf)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].readonly = true
    vim.bo[buf].modifiable = false
    if vim.api.nvim_get_current_buf() == buf then
        vim.wo.conceallevel = 0
        vim.wo.wrap = false
    end
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
    local span = profile.begin("refresh.async.wall")
    request.span = span
    vim.schedule(function()
        if active ~= request then
            profile.finish(span)
            return
        end
        local function complete(view, err, data)
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
                publish(buf, view, data)
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
        local ok, cancel = pcall(function()
            return require("taskbuffer.list").view_async(runtime, complete)
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
    local buf = vim.fn.bufnr(view_name)
    if buf == -1 then
        buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_buf_set_name(buf, view_name)
    end
    if vim.api.nvim_get_current_buf() ~= buf then
        vim.cmd("buffer " .. buf)
    end
    M.prepare(vim.api.nvim_get_current_buf())
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
M.apply_local_change = profile.wrap("action.publish", M.apply_local_change)
M.refresh_and_restore_cursor = profile.wrap("refresh.request", M.refresh_and_restore_cursor)
M.tasks = profile.wrap("tasks.command", M.tasks)
M.tasks_clear = profile.wrap("tasks_clear.command", M.tasks_clear)
return M
