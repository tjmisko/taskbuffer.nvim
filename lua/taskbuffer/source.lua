-- On-demand source-file safety shared by actions, date edits, and undo.
local M = {}
local uv = vim.uv

local function canonical(path)
    return uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
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
    for _, buf in ipairs(buffers(path)) do
        if vim.bo[buf].modified then
            return false, "save unsaved source edits first: " .. path
        end
    end
    return true
end

function M.version(path)
    local stat = uv.fs_stat(path)
    if not stat then
        return nil
    end
    return table.concat({ stat.size, stat.ino, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ":")
end

-- Refresh clean loaded buffers without replacing the current window or firing
-- FileType/BufEnter refresh loops. Modified buffers are never reloaded.
local function reload(path)
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

-- Stage beside the destination and rename only after a successful write/close.
-- Preserve permissions and resolve symlinks so editing a link keeps the link.
function M.write(path, data)
    local ok, err = M.check(path)
    if not ok then
        return false, err
    end
    local target = canonical(path)
    local stat = uv.fs_stat(target)
    if stat and stat.nlink > 1 then
        return false, "cannot safely replace a source with multiple hard links: " .. path
    end
    if stat and vim.fn.filewritable(target) ~= 1 then
        return false, "source file is not writable: " .. path
    end
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
        -- libuv has no portable ACL/xattr API. The platform copy utility keeps
        -- those attributes on the staged file before its contents are changed.
        -- This runs only for an explicit source edit, never setup or scanning.
        local flag = uv.os_uname().sysname == "Linux" and "--preserve=mode,ownership,timestamps,xattr" or "-p"
        local spawned, copy = pcall(function()
            return vim.system({ "cp", flag, target, temporary }, { text = true }):wait()
        end)
        if not spawned or copy.code ~= 0 then
            return fail("cannot preserve source metadata: " .. (spawned and copy.stderr or tostring(copy)))
        end
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
    reload(path)
    return true
end

return M
