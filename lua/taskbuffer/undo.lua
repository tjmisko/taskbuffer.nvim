local M = {}

local util = require("taskbuffer.util")

local MAX_STACK = 100

---@class UndoEdit
---@field filepath string
---@field linenumber integer
---@field old_line string
---@field new_line string

---@class UndoEntry
---@field op string
---@field edits UndoEdit[]
---@field timestamp integer

---@type UndoEntry[]
local undo_stack = {}
---@type UndoEntry[]
local redo_stack = {}

---@param entry UndoEntry
function M.push(entry)
    undo_stack[#undo_stack + 1] = entry
    if #undo_stack > MAX_STACK then
        table.remove(undo_stack, 1)
    end
    redo_stack = {}
end

--- Flash matching taskfile lines after an undo/redo operation.
---@param edits UndoEdit[]
local function flash_edits(edits)
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local ns = vim.api.nvim_create_namespace("taskbuffer_undo_flash")

    -- Build a set of filepath:linenumber keys from the edits
    local edit_keys = {}
    for _, edit in ipairs(edits) do
        edit_keys[edit.filepath .. ":" .. edit.linenumber] = true
    end

    for i, line in ipairs(lines) do
        local ok, filepath, linenumber = pcall(util.parse_taskfile_line, line)
        if ok and filepath and linenumber then
            if edit_keys[filepath .. ":" .. linenumber] then
                vim.api.nvim_buf_add_highlight(buf, ns, "Search", i - 1, 0, -1)
            end
        end
    end

    vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
    end, 500)
end

--- Format a count string for notifications.
---@param n integer
---@return string
local function task_count(n)
    return n == 1 and "1 task" or (n .. " tasks")
end

function M.undo()
    if #undo_stack == 0 then
        vim.notify("[taskbuffer] nothing to undo", vim.log.levels.INFO)
        return
    end

    local entry = undo_stack[#undo_stack]

    -- Validate all edits before applying any
    for _, edit in ipairs(entry.edits) do
        local current = util.read_line_from_file(edit.filepath, edit.linenumber)
        if current ~= edit.new_line then
            vim.notify("[taskbuffer] undo refused: source file modified externally", vim.log.levels.WARN)
            return
        end
    end

    -- Apply all edits (reverse order to avoid line drift within same file)
    local edits_sorted = vim.deepcopy(entry.edits)
    table.sort(edits_sorted, function(a, b)
        if a.filepath == b.filepath then
            return a.linenumber > b.linenumber
        end
        return a.filepath > b.filepath
    end)
    for _, edit in ipairs(edits_sorted) do
        util.replace_line_in_file(edit.filepath, edit.linenumber, edit.old_line)
    end

    table.remove(undo_stack)
    redo_stack[#redo_stack + 1] = entry

    require("taskbuffer.buffer").refresh_and_restore_cursor()
    flash_edits(entry.edits)
    vim.notify("[taskbuffer] undid: " .. entry.op .. " (" .. task_count(#entry.edits) .. ")", vim.log.levels.INFO)
end

function M.redo()
    if #redo_stack == 0 then
        vim.notify("[taskbuffer] nothing to redo", vim.log.levels.INFO)
        return
    end

    local entry = redo_stack[#redo_stack]

    -- Validate all edits before applying any
    for _, edit in ipairs(entry.edits) do
        local current = util.read_line_from_file(edit.filepath, edit.linenumber)
        if current ~= edit.old_line then
            vim.notify("[taskbuffer] redo refused: source file modified externally", vim.log.levels.WARN)
            return
        end
    end

    -- Apply all edits (reverse order to avoid line drift within same file)
    local edits_sorted = vim.deepcopy(entry.edits)
    table.sort(edits_sorted, function(a, b)
        if a.filepath == b.filepath then
            return a.linenumber > b.linenumber
        end
        return a.filepath > b.filepath
    end)
    for _, edit in ipairs(edits_sorted) do
        util.replace_line_in_file(edit.filepath, edit.linenumber, edit.new_line)
    end

    table.remove(redo_stack)
    undo_stack[#undo_stack + 1] = entry

    require("taskbuffer.buffer").refresh_and_restore_cursor()
    flash_edits(entry.edits)
    vim.notify("[taskbuffer] redid: " .. entry.op .. " (" .. task_count(#entry.edits) .. ")", vim.log.levels.INFO)
end

function M.reset()
    undo_stack = {}
    redo_stack = {}
end

return M
