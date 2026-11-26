-- On-demand source-file safety shared by actions, date edits, and undo.
local M = {}
local uv = vim.uv
local xattr = require("taskbuffer.xattr")
local editing

-- Pending contents of list-originated edits, keyed by canonical path. The
-- writer (writer.lua) persists them in the background:
--   base     { data, version } the content the edit records are relative to
--   data     the latest in-memory content (what readers and the index see)
--   edits    hunks { line, old_lines, new_lines } not yet handed to the writer
--   inflight the batch { data, edits } currently being written, or nil
---@type table<string, table>
M.overlay = {}
local overlay = M.overlay

local function canonical(path)
    return uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end
M.canonical = canonical

--- The staged state for a path, or nil. Cheap when nothing is staged.
---@param path string
---@return table|nil
function M.staged(path)
    if next(overlay) == nil then
        return nil
    end
    return overlay[path] or overlay[canonical(path)]
end

--- Is a list-originated edit for this path not yet on disk?
---@param path string
---@return boolean
function M.pending(path)
    return M.staged(path) ~= nil
end

local function editing_path(path)
    return editing and (path == editing.path or canonical(path) == canonical(editing.path))
end

-- Only an explicitly selected source buffer supplies unsaved contents. Actions
-- from the aggregate view still use disk snapshots and reject dirty sources.
function M.read(path)
    if editing_path(path) then
        return editing.data
    end
    local staged = M.staged(path)
    if staged then
        return staged.data
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a") or ""
    file:close()
    return data
end

-- Run synchronous source mutations against an in-memory snapshot, then publish
-- once. Checkbox + marker changes form one native undo entry and emit normal
-- buffer-change events; unrelated edits, file options, and disk bytes stay put.
function M.edit_buffer(buf, callback)
    if editing then
        return false, "a source buffer edit is already in progress"
    end
    if buf == 0 then
        buf = vim.api.nvim_get_current_buf()
    end
    if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
        return false, "source buffer is not editable"
    end
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local snapshot = {
        path = vim.api.nvim_buf_get_name(buf),
        data = table.concat(before, "\n") .. (vim.bo[buf].endofline and "\n" or ""),
    }
    editing = snapshot
    local called, ok, err = pcall(callback)
    editing = nil
    if not called then
        return false, ok
    end
    if not ok then
        return false, err
    end
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        return false, "source buffer changed during the task action"
    end
    local after = vim.split(snapshot.data, "\n", { plain = true })
    if #after > 1 and after[#after] == "" then
        table.remove(after)
    end
    -- Replace only the changed lines so marks on surrounding text survive.
    local first, last_before, last_after = 1, #before, #after
    while first <= last_before and first <= last_after and before[first] == after[first] do
        first = first + 1
    end
    while last_before >= first and last_after >= first and before[last_before] == after[last_after] do
        last_before = last_before - 1
        last_after = last_after - 1
    end
    if first <= last_before or first <= last_after then
        vim.api.nvim_buf_set_lines(buf, first - 1, last_before, false, vim.list_slice(after, first, last_after))
    end
    return true
end

local function buffers(path)
    local found = {}
    local target = canonical(path)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" and canonical(name) == target then
                found[#found + 1] = buf
            end
        end
    end
    return found
end

function M.check(path)
    if editing_path(path) then
        return true
    end
    for _, buf in ipairs(buffers(path)) do
        if vim.bo[buf].modified then
            return false, "save unsaved source edits first: " .. path
        end
    end
    return true
end

---@param stat table uv stat result
---@return string
function M.version_of(stat)
    return table.concat({ stat.size, stat.ino, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ":")
end

function M.version(path)
    local stat = uv.fs_stat(path)
    if not stat then
        return nil
    end
    return M.version_of(stat)
end

-- Refresh clean loaded buffers without replacing the current window or firing
-- FileType/BufEnter refresh loops. Modified buffers are never reloaded.
function M.reload(path)
    for _, buf in ipairs(buffers(path)) do
        if not vim.bo[buf].modified then
            local views = {}
            for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
            end
            vim.api.nvim_buf_call(buf, function()
                vim.cmd("silent noautocmd edit!")
            end)
            for win, view in pairs(views) do
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_call(win, function()
                        vim.fn.winrestview(view)
                    end)
                end
            end
        end
    end
end

---@param text string
---@return string[]
local function split_lines(text)
    return vim.split(text, "\n", { plain = true })
end

local function same_lines(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

--- The single changed hunk between two contents (common prefix/suffix lines
--- trimmed), or nil when they are identical.
---@param old string
---@param new string
---@return table|nil hunk { line, old_lines, new_lines }
function M.diff_hunk(old, new)
    if old == new then
        return nil
    end
    local before, after = split_lines(old), split_lines(new)
    local first, last_before, last_after = 1, #before, #after
    while first <= last_before and first <= last_after and before[first] == after[first] do
        first = first + 1
    end
    while last_before >= first and last_after >= first and before[last_before] == after[last_after] do
        last_before = last_before - 1
        last_after = last_after - 1
    end
    return {
        line = first,
        old_lines = vim.list_slice(before, first, last_before),
        new_lines = vim.list_slice(after, first, last_after),
    }
end

-- Consecutive edits of the same lines (check, then marker) form one record, so
-- one undo entry corresponds to one record. An edit that restores the original
-- text removes the record altogether.
local function add_edit(edits, hunk)
    local last = edits[#edits]
    if last and last.line == hunk.line and same_lines(last.new_lines, hunk.old_lines) then
        last.new_lines = hunk.new_lines
        if same_lines(last.old_lines, last.new_lines) then
            edits[#edits] = nil
        end
        return
    end
    edits[#edits + 1] = hunk
end

local function sync_index(target, data)
    local index = package.loaded["taskbuffer.index"]
    if not index or not index.accepts(target) then
        return
    end
    local entry = index.entry(target)
    index.update_file(target, data, entry and entry.version)
end

local function refuse_unwritable(path, target)
    local stat = uv.fs_stat(target)
    if stat and stat.nlink > 1 then
        return "cannot safely replace a source with multiple hard links: " .. path
    end
    if stat and vim.fn.filewritable(target) ~= 1 then
        return "source file is not writable: " .. path
    end
    return nil
end

-- Record the new contents in memory. The index and every reader see them at
-- once; the writer persists them in the background (R2, R10). A file that does
-- not exist yet has nothing to rebase onto, so it is written immediately.
function M.write(path, data)
    if editing_path(path) then
        editing.data = data
        return true
    end
    local ok, err = M.check(path)
    if not ok then
        return false, err
    end
    local target = canonical(path)
    local refusal = refuse_unwritable(path, target)
    if refusal then
        return false, refusal
    end
    local state = overlay[target]
    if not state then
        local previous = M.read(target)
        if previous == nil then
            return M.write_now(path, data)
        end
        state = { base = { data = previous, version = M.version(target) }, data = previous, edits = {} }
    end
    local hunk = M.diff_hunk(state.data, data)
    if not hunk then
        return true
    end
    add_edit(state.edits, hunk)
    state.data = data
    overlay[target] = state
    sync_index(target, data)
    require("taskbuffer.writer").enqueue(target)
    return true
end

-- Stage beside the destination and rename only after a successful write/close.
-- Preserve permissions and resolve symlinks so editing a link keeps the link.
-- Synchronous: used for files outside the index (state file) and new files.
function M.write_now(path, data)
    if editing_path(path) then
        editing.data = data
        return true
    end
    local ok, err = M.check(path)
    if not ok then
        return false, err
    end
    local target = canonical(path)
    local refusal = refuse_unwritable(path, target)
    if refusal then
        return false, refusal
    end
    local stat = uv.fs_stat(target)
    local fd, temporary = uv.fs_mkstemp(target .. ".taskbuffer-XXXXXX")
    if not fd then
        return false, temporary
    end
    local function fail(reason)
        if fd then
            uv.fs_close(fd)
        end
        uv.fs_unlink(temporary)
        return false, reason
    end
    if stat then
        -- Keep mode bits and user.* xattrs on the staged file. No subprocess.
        -- Timestamps are not preserved; ownership is left to the OS.
        local chmod_ok, chmod_err = uv.fs_fchmod(fd, stat.mode % 4096)
        if not chmod_ok then
            return fail("cannot preserve source metadata: " .. tostring(chmod_err))
        end
        xattr.copy_user(target, temporary)
    end
    local written
    written, err = uv.fs_write(fd, data, 0)
    if written ~= #data then
        return fail(err or "incomplete source write: " .. path)
    end
    ok, err = uv.fs_ftruncate(fd, #data)
    if not ok then
        return fail(err)
    end
    ok, err = uv.fs_close(fd)
    fd = nil
    if not ok then
        return fail(err)
    end
    ok, err = uv.fs_rename(temporary, target)
    if not ok then
        return fail(err)
    end
    M.reload(path)
    return true
end

return M
