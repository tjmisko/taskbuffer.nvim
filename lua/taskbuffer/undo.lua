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
    local buffer = require("taskbuffer.buffer")
    local ns = vim.api.nvim_create_namespace("taskbuffer_undo_flash")

    -- Build a set of filepath:linenumber keys from the edits
    local edit_keys = {}
    for _, edit in ipairs(edits) do
        edit_keys[edit.filepath .. ":" .. edit.linenumber] = true
    end

    for i = 1, vim.api.nvim_buf_line_count(buf) do
        local task = buffer.task_at(i, buf)
        if task then
            if edit_keys[task.file_path .. ":" .. task.line_number] then
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
        if not util.check_source(edit.filepath) then
            return
        end
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
        if not util.replace_line_in_file(edit.filepath, edit.linenumber, edit.old_line) then
            return
        end
    end

    table.remove(undo_stack)
    redo_stack[#redo_stack + 1] = entry

    local buf = vim.api.nvim_get_current_buf()
    require("taskbuffer.buffer").apply_local_change(function(err)
        if not err and vim.api.nvim_get_current_buf() == buf then
            flash_edits(entry.edits)
        end
    end)
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
        if not util.check_source(edit.filepath) then
            return
        end
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
        if not util.replace_line_in_file(edit.filepath, edit.linenumber, edit.new_line) then
            return
        end
    end

    table.remove(redo_stack)
    undo_stack[#undo_stack + 1] = entry

    local buf = vim.api.nvim_get_current_buf()
    require("taskbuffer.buffer").apply_local_change(function(err)
        if not err and vim.api.nvim_get_current_buf() == buf then
            flash_edits(entry.edits)
        end
    end)
    vim.notify("[taskbuffer] redid: " .. entry.op .. " (" .. task_count(#entry.edits) .. ")", vim.log.levels.INFO)
end

local function remove_edit(stack, position, index)
    local entry = stack[position]
    table.remove(entry.edits, index)
    if #entry.edits == 0 then
        table.remove(stack, position)
    end
end

-- Find an edit on this file whose old_line is `text`, searching oldest first.
local function find_forward(stack, path, text, source)
    for position = 1, #stack do
        local edits = stack[position].edits
        for index = 1, #edits do
            if edits[index].old_line == text and source.canonical(edits[index].filepath) == path then
                return position, index
            end
        end
    end
    return nil
end

-- Walk the chain old -> ... -> new through the stacks, dropping each link.
-- The writer merges consecutive edits of one line into a single record, so one
-- record can span several undo edits (L0->L1, L1->L2).
local function drop_chain(stack, path, old_line, new_line, source)
    local dropped = 0
    local current = old_line
    while current ~= new_line and dropped < 1000 do
        local position, index = find_forward(stack, path, current, source)
        if not position then
            break
        end
        current = stack[position].edits[index].new_line
        remove_edit(stack, position, index)
        dropped = dropped + 1
    end
    return dropped > 0 and current == new_line
end

--- Forget the edits whose write was reverted; entries go when they empty.
---@param path string canonical path of the file
---@param record table writer record { old_lines, new_lines }
function M.drop_edit(path, record)
    local source = require("taskbuffer.source")
    local old_line, new_line = record.old_lines[1], record.new_lines[1]
    -- Probe first so a failed chain removes nothing.
    local function chain_exists(stack)
        local current, steps = old_line, 0
        while current ~= new_line and steps < 1000 do
            local position, index = find_forward(stack, path, current, source)
            if not position then
                return false
            end
            current = stack[position].edits[index].new_line
            steps = steps + 1
        end
        return current == new_line
    end
    for _, stack in ipairs({ undo_stack, redo_stack }) do
        if chain_exists(stack) then
            drop_chain(stack, path, old_line, new_line, source)
            return
        end
    end
    -- Reverse-direction records (from undo/redo) match a single edit backwards.
    local function drop_backward(stack)
        for position = #stack, 1, -1 do
            local edits = stack[position].edits
            for index = #edits, 1, -1 do
                local edit = edits[index]
                if
                    edit.old_line == new_line
                    and edit.new_line == old_line
                    and source.canonical(edit.filepath) == path
                then
                    remove_edit(stack, position, index)
                    return true
                end
            end
        end
        return false
    end
    if not drop_backward(undo_stack) then
        drop_backward(redo_stack)
    end
end

---@return integer undo_entries
---@return integer redo_entries
function M.depth()
    return #undo_stack, #redo_stack
end

function M.reset()
    undo_stack = {}
    redo_stack = {}
end

return M
