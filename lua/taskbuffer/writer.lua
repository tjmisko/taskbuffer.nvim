-- writer.lua: background persistence of staged source edits (source.overlay).
--
-- One write per path is in flight at a time; edits that arrive meanwhile are
-- coalesced into the next write. Every disk operation is an async uv call, so
-- a write never blocks input. Before writing, the current disk content is
-- compared with the content the edit records are relative to (the base):
--   equal      write the staged content as it is
--   different  rebase each record onto the disk content (same line, else the
--              unique match elsewhere); records that fit nowhere conflict
-- Conflicting records and failed writes are reverted in memory, their undo
-- entries dropped, and the user warned once per file.

local uv = vim.uv or vim.loop
local source = require("taskbuffer.source")
local xattr = require("taskbuffer.xattr")

local M = {}

local overlay = source.overlay
local queued = {} -- path -> true while a start is scheduled
local running = {} -- path -> true while a write is in flight
local FLUSH_TIMEOUT = 10000

-- Rebase -----------------------------------------------------------------

local function matches_at(lines, at, old_lines)
    if at < 1 or at + #old_lines - 1 > #lines then
        return false
    end
    for offset = 1, #old_lines do
        if lines[at + offset - 1] ~= old_lines[offset] then
            return false
        end
    end
    return true
end

-- Where a record applies in `lines`: its own line, else the one exact match.
local function locate(lines, record)
    local old_lines = record.old_lines
    if #old_lines == 0 then
        return record.line <= #lines + 1 and record.line or nil
    end
    if matches_at(lines, record.line, old_lines) then
        return record.line
    end
    local found
    for at = 1, #lines - #old_lines + 1 do
        if lines[at] == old_lines[1] and matches_at(lines, at, old_lines) then
            if found then
                return nil
            end
            found = at
        end
    end
    return found
end

local function splice(lines, at, removed, inserted)
    if removed == #inserted then
        for offset = 1, removed do
            lines[at + offset - 1] = inserted[offset]
        end
        return lines
    end
    local result = {}
    for position = 1, at - 1 do
        result[#result + 1] = lines[position]
    end
    for _, line in ipairs(inserted) do
        result[#result + 1] = line
    end
    for position = at + removed, #lines do
        result[#result + 1] = lines[position]
    end
    return result
end

--- Apply edit records to disk content, each independently.
---@param disk string
---@param edits table[] records { line, old_lines, new_lines }
---@return string data the rebased content
---@return table[] conflicts records that could not be placed
function M.rebase(disk, edits)
    local lines = vim.split(disk, "\n", { plain = true })
    local conflicts = {}
    for _, record in ipairs(edits) do
        local at = locate(lines, record)
        if at then
            lines = splice(lines, at, #record.old_lines, record.new_lines)
        else
            conflicts[#conflicts + 1] = record
        end
    end
    return table.concat(lines, "\n"), conflicts
end

-- Async primitives ----------------------------------------------------------

-- Call a callback-style uv function from inside a coroutine; returns what the
-- callback received (err, ...). The coroutine is resumed from the uv callback.
local failure_handlers = setmetatable({}, { __mode = "k" })

local function await(fn, ...)
    local thread = coroutine.running()
    local args = { ... }
    args[#args + 1] = function(...)
        local ok, err = coroutine.resume(thread, ...)
        local handler = not ok and failure_handlers[thread]
        if handler then
            vim.schedule(function()
                handler(err)
            end)
        end
    end
    fn(unpack(args, 1, #args))
    return coroutine.yield()
end

local function read_disk(path)
    local err, fd = await(uv.fs_open, path, "r", 438)
    if err then
        return nil, nil, err
    end
    local stat_err, stat = await(uv.fs_fstat, fd)
    if stat_err then
        await(uv.fs_close, fd)
        return nil, nil, stat_err
    end
    local read_err, data = await(uv.fs_read, fd, stat.size, 0)
    await(uv.fs_close, fd)
    if read_err then
        return nil, nil, read_err
    end
    return data or "", source.version_of(stat), nil
end

-- Stage in a temp file beside the destination, then rename over it.
local function replace_file(path, stat, data)
    local err, fd, temporary = await(uv.fs_mkstemp, path .. ".taskbuffer-XXXXXX")
    if err or not fd then
        return nil, err or "cannot create a temporary file beside " .. path
    end
    local function fail(reason)
        if fd then
            await(uv.fs_close, fd)
        end
        await(uv.fs_unlink, temporary)
        return nil, reason
    end
    local failure = await(uv.fs_fchmod, fd, stat.mode % 4096)
    if failure then
        return fail("cannot preserve source metadata: " .. tostring(failure))
    end
    xattr.copy_user(path, temporary)
    local write_err, written = await(uv.fs_write, fd, data, 0)
    if write_err or written ~= #data then
        return fail(write_err or "incomplete source write: " .. path)
    end
    failure = await(uv.fs_ftruncate, fd, #data)
    if failure then
        return fail(failure)
    end
    failure = await(uv.fs_close, fd)
    fd = nil
    if failure then
        return fail(failure)
    end
    failure = await(uv.fs_rename, temporary, path)
    if failure then
        return fail(failure)
    end
    local _, renamed = await(uv.fs_stat, path)
    return renamed and source.version_of(renamed) or true
end

-- Runs inside a coroutine. Returns a result table or nil, err.
local function commit(path, state, batch)
    local stat_err, stat = await(uv.fs_stat, path)
    if stat_err or not stat then
        return nil, "source file is missing: " .. path
    end
    if stat.nlink > 1 then
        return nil, "cannot safely replace a source with multiple hard links: " .. path
    end
    local access_err, writable = await(uv.fs_access, path, "W")
    if access_err or not writable then
        return nil, "source file is not writable: " .. path
    end
    local disk, version, err = read_disk(path)
    if not disk then
        return nil, err
    end
    local target, conflicts = batch.data, {}
    if disk ~= state.base.data then
        target, conflicts = M.rebase(disk, batch.edits)
    end
    if target == disk then
        return { data = disk, version = version, conflicts = conflicts, wrote = false }
    end
    local written, write_err = replace_file(path, stat, target)
    if not written then
        return nil, write_err
    end
    return {
        data = target,
        version = type(written) == "string" and written or nil,
        conflicts = conflicts,
        wrote = true,
    }
end

-- Main-thread completion -----------------------------------------------------

local function summarize(record)
    local line = (record.new_lines[1] or record.old_lines[1] or ""):gsub("%s+$", "")
    return line ~= "" and line or "(blank line)"
end

local function warn(path, records, reason)
    local text = summarize(records[1])
    if #records > 1 then
        text = text .. " (and " .. (#records - 1) .. " more)"
    end
    vim.notify(("[taskbuffer] reverted change to %s: %s: %s"):format(path, reason, text), vim.log.levels.WARN)
end

local function drop_undo_entries(path, records)
    local undo = package.loaded["taskbuffer.undo"]
    if not undo then
        return
    end
    for _, record in ipairs(records) do
        undo.drop_edit(path, record)
    end
end

local function rerender()
    local buffer = package.loaded["taskbuffer.buffer"]
    if not buffer then
        return
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "taskfile" then
            buffer.refresh_taskfile_async(nil, { buf = buf, reuse = true })
        end
    end
end

local function index_module()
    local index = package.loaded["taskbuffer.index"]
    return index and index.accepts and index
end

local function finish(path, state, batch, result, err)
    running[path] = nil
    state.inflight = nil
    local reverted = false
    if not result then
        -- The write failed: nothing reached disk. Everything staged on top of
        -- the failed batch rests on it, so the whole overlay goes.
        local records = vim.list_extend(vim.deepcopy(batch.edits), state.edits)
        overlay[path] = nil
        drop_undo_entries(path, records)
        local index = index_module()
        if index and index.accepts(path) then
            index.update_file_from_disk(path)
        end
        warn(path, #records > 0 and records or { { old_lines = {}, new_lines = {} } }, tostring(err))
        rerender()
        return
    end
    if #result.conflicts > 0 then
        reverted = true
        drop_undo_entries(path, result.conflicts)
        warn(path, result.conflicts, "the file changed on disk")
    end
    -- Later records are relative to what we staged, not to what landed.
    state.base = { data = batch.data, version = result.version }
    local settled = #state.edits == 0
    local index = index_module()
    if settled then
        overlay[path] = nil
        if index and index.accepts(path) then
            if result.data ~= batch.data then
                index.update_file(path, result.data, result.version)
                reverted = true
            elseif result.version then
                index.set_version(path, result.version)
            end
        end
    end
    if result.wrote then
        source.reload(path)
    end
    if reverted then
        rerender()
    end
    if not settled then
        M.enqueue(path)
    end
end

local function start(path)
    local state = overlay[path]
    if not state or running[path] then
        return
    end
    if #state.edits == 0 then
        overlay[path] = nil
        return
    end
    local batch = { data = state.data, edits = state.edits }
    state.edits = {}
    state.inflight = batch
    running[path] = true
    local thread = coroutine.create(function()
        local result, err = commit(path, state, batch)
        vim.schedule(function()
            finish(path, state, batch, result, err)
        end)
    end)
    failure_handlers[thread] = function(err)
        finish(path, state, batch, nil, err)
    end
    local ok, err = coroutine.resume(thread)
    if not ok then
        vim.schedule(function()
            finish(path, state, batch, nil, err)
        end)
    end
end

-- Public API -------------------------------------------------------------------

--- Ask for the staged content of a path to be written soon. Several edits in
--- the same tick share one write.
---@param path string canonical path
function M.enqueue(path)
    if queued[path] or running[path] then
        return
    end
    queued[path] = true
    vim.schedule(function()
        queued[path] = nil
        start(path)
    end)
end

--- True when nothing is staged, queued, or being written.
---@return boolean
function M.idle()
    return next(overlay) == nil and next(running) == nil
end

--- Persist everything now and wait for it. For VimLeavePre and tests.
---@param timeout integer|nil milliseconds, default 10000
---@return boolean drained
function M.flush_sync(timeout)
    local paths = {}
    for path in pairs(overlay) do
        paths[#paths + 1] = path
    end
    for _, path in ipairs(paths) do
        queued[path] = nil
        start(path)
    end
    return vim.wait(timeout or FLUSH_TIMEOUT, function()
        return M.idle()
    end, 2)
end

return M
