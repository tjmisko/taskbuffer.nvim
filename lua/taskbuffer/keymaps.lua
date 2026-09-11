local M = {}

local util = require("taskbuffer.util")

local function get_config()
    return require("taskbuffer.config").values
end

--- Look up a keymap binding from config; returns nil if set to false.
local function binding(context, action)
    local cfg = get_config()
    local group = cfg.keymaps[context]
    if not group then
        return nil
    end
    local key = group[action]
    if key == false then
        return nil
    end
    return key
end

--- Set a keymap only if the binding is not disabled.
local function map(mode, context, action, rhs, opts)
    local lhs = binding(context, action)
    if not lhs then
        return
    end
    vim.keymap.set(mode, lhs, rhs, opts or {})
end

--- Detect the key bound to a vim command (e.g., "undo", "redo").
--- Falls back to the builtin default if no custom mapping found.
---@param command string
---@param builtin_default string
---@return string
local function detect_key(command, builtin_default)
    local existing = vim.fn.maparg(builtin_default, "n", false, true)
    if vim.tbl_isempty(existing) then
        return builtin_default
    end
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        local rhs = (m.rhs or ""):lower()
        if rhs:match(command) or rhs:match(vim.pesc(builtin_default:lower())) then
            return m.lhs
        end
    end
    return builtin_default
end

--- Bulk-shift due dates for multiple taskfile lines.
--- Groups edits by source file and processes from bottom-up to avoid line drift.
--- Falls back to frontmatter due date for undated tasks (deduplicated per file).
---@param lines string[]
---@param days integer
local function shift_task_dates_bulk(lines, days)
    for _, line in ipairs(lines) do
        local path = util.parse_taskfile_line(line)
        if path and not util.taskfile_location(line) then
            return
        end
    end
    local buffer = require("taskbuffer.buffer")
    local cfg = get_config()
    local edits_by_file = {}
    local all_edits = {}
    local shifted = 0
    local fm_shifted_files = {} -- track FM edits to deduplicate per file
    for _, line in ipairs(lines) do
        local filepath, linenumber = util.parse_taskfile_line(line)
        if filepath and linenumber then
            local source_line = util.read_line_from_file(filepath, linenumber)
            if source_line then
                local new_line = util.shift_date_in_string(source_line, days)
                if new_line then
                    if not edits_by_file[filepath] then
                        edits_by_file[filepath] = {}
                    end
                    local edit =
                        { filepath = filepath, linenumber = linenumber, old_line = source_line, new_line = new_line }
                    table.insert(edits_by_file[filepath], edit)
                    all_edits[#all_edits + 1] = edit
                    shifted = shifted + 1
                elseif cfg.frontmatter and cfg.frontmatter.inherit_due and not fm_shifted_files[filepath] then
                    local due_key = cfg.frontmatter.due_key or "due"
                    local fm_new_date, fm_line, old_fm_line, new_fm_line =
                        util.shift_frontmatter_due(filepath, days, due_key)
                    if fm_new_date then
                        fm_shifted_files[filepath] = true
                        all_edits[#all_edits + 1] = {
                            filepath = filepath,
                            linenumber = fm_line,
                            old_line = old_fm_line,
                            new_line = new_fm_line,
                        }
                        shifted = shifted + 1
                    end
                end
            end
        end
    end
    if shifted == 0 then
        vim.notify("[taskbuffer] no dated tasks in selection", vim.log.levels.WARN)
        return
    end
    -- Apply inline edits per file, sorted by line number descending to avoid drift
    for _, edits in pairs(edits_by_file) do
        table.sort(edits, function(a, b)
            return a.linenumber > b.linenumber
        end)
        for _, edit in ipairs(edits) do
            util.replace_line_in_file(edit.filepath, edit.linenumber, edit.new_line)
        end
    end
    -- FM edits were already applied in shift_frontmatter_due
    local direction = days > 0 and "forward" or "back"
    local op = "shift " .. direction .. " " .. math.abs(days) .. " day(s)"
    require("taskbuffer.undo").push({ op = op, edits = all_edits, timestamp = os.time() })
    buffer.refresh_and_restore_cursor()
    vim.notify(
        "[taskbuffer] shifted " .. shifted .. " task(s) " .. direction .. " " .. math.abs(days) .. " day(s)",
        vim.log.levels.INFO
    )
end

--- Get filepath and linenumber from a taskfile line.
local function get_task_location_from_taskfile()
    local line = vim.fn.getline(".")
    return util.taskfile_location(line)
end

local function get_task_location_from_current_buffer()
    local filepath = vim.api.nvim_buf_get_name(0)
    local linenumber = vim.api.nvim_win_get_cursor(0)[1]
    return filepath, linenumber
end

local function shift_task_date_in_taskfile(days)
    local buffer = require("taskbuffer.buffer")
    local cfg = get_config()
    local line = vim.api.nvim_get_current_line()
    local filepath, linenumber = util.taskfile_location(line)
    if not filepath or not linenumber then
        vim.notify("[taskbuffer] could not parse taskfile line", vim.log.levels.WARN)
        return
    end
    local source_line = util.read_line_from_file(filepath, linenumber)
    if not source_line then
        vim.notify("[taskbuffer] could not read source line", vim.log.levels.WARN)
        return
    end
    local new_line, new_date = util.shift_date_in_string(source_line, days)
    if new_line then
        if not util.replace_line_in_file(filepath, linenumber, new_line) then
            return
        end
        local direction = days > 0 and "forward" or "back"
        local op = "shift " .. direction .. " " .. math.abs(days) .. " day(s)"
        require("taskbuffer.undo").push({
            op = op,
            edits = { { filepath = filepath, linenumber = linenumber, old_line = source_line, new_line = new_line } },
            timestamp = os.time(),
        })
        buffer.refresh_and_restore_cursor()
        vim.notify("[taskbuffer] due: " .. new_date, vim.log.levels.INFO)
        return
    end

    -- Fallback: shift frontmatter due date
    if cfg.frontmatter and cfg.frontmatter.inherit_due then
        local due_key = cfg.frontmatter.due_key or "due"
        local fm_new_date, fm_line, old_fm_line, new_fm_line = util.shift_frontmatter_due(filepath, days, due_key)
        if fm_new_date then
            local direction = days > 0 and "forward" or "back"
            local op = "shift FM " .. direction .. " " .. math.abs(days) .. " day(s)"
            require("taskbuffer.undo").push({
                op = op,
                edits = {
                    { filepath = filepath, linenumber = fm_line, old_line = old_fm_line, new_line = new_fm_line },
                },
                timestamp = os.time(),
            })
            buffer.refresh_and_restore_cursor()
            vim.notify("[taskbuffer] FM due: " .. fm_new_date, vim.log.levels.INFO)
            return
        end
    end

    vim.notify("[taskbuffer] no date found on this line", vim.log.levels.WARN)
end

--- Bulk-set due dates to today for multiple taskfile lines.
--- Falls back to frontmatter due date for undated tasks (deduplicated per file).
---@param lines string[]
local function set_task_dates_today_bulk(lines)
    for _, line in ipairs(lines) do
        local path = util.parse_taskfile_line(line)
        if path and not util.taskfile_location(line) then
            return
        end
    end
    local buffer = require("taskbuffer.buffer")
    local cfg = get_config()
    local edits_by_file = {}
    local all_edits = {}
    local updated = 0
    local fm_set_files = {} -- track FM edits to deduplicate per file
    for _, line in ipairs(lines) do
        local filepath, linenumber = util.parse_taskfile_line(line)
        if filepath and linenumber then
            local source_line = util.read_line_from_file(filepath, linenumber)
            if source_line then
                local new_line = util.set_date_today_in_string(source_line)
                if new_line then
                    if not edits_by_file[filepath] then
                        edits_by_file[filepath] = {}
                    end
                    local edit =
                        { filepath = filepath, linenumber = linenumber, old_line = source_line, new_line = new_line }
                    table.insert(edits_by_file[filepath], edit)
                    all_edits[#all_edits + 1] = edit
                    updated = updated + 1
                elseif cfg.frontmatter and cfg.frontmatter.inherit_due and not fm_set_files[filepath] then
                    local due_key = cfg.frontmatter.due_key or "due"
                    local fm_new_date, fm_line, old_fm_line, new_fm_line =
                        util.set_frontmatter_due_today(filepath, due_key)
                    if fm_new_date then
                        fm_set_files[filepath] = true
                        all_edits[#all_edits + 1] = {
                            filepath = filepath,
                            linenumber = fm_line,
                            old_line = old_fm_line,
                            new_line = new_fm_line,
                        }
                        updated = updated + 1
                    end
                end
            end
        end
    end
    if updated == 0 then
        vim.notify("[taskbuffer] no dated tasks in selection", vim.log.levels.WARN)
        return
    end
    for _, edits in pairs(edits_by_file) do
        table.sort(edits, function(a, b)
            return a.linenumber > b.linenumber
        end)
        for _, edit in ipairs(edits) do
            util.replace_line_in_file(edit.filepath, edit.linenumber, edit.new_line)
        end
    end
    -- FM edits were already applied in set_frontmatter_due_today
    require("taskbuffer.undo").push({ op = "set today", edits = all_edits, timestamp = os.time() })
    buffer.refresh_and_restore_cursor()
    vim.notify("[taskbuffer] set " .. updated .. " task(s) to today", vim.log.levels.INFO)
end

local function set_date_today_in_taskfile()
    local buffer = require("taskbuffer.buffer")
    local cfg = get_config()
    local line = vim.api.nvim_get_current_line()
    local filepath, linenumber = util.taskfile_location(line)
    if not filepath or not linenumber then
        vim.notify("[taskbuffer] could not parse taskfile line", vim.log.levels.WARN)
        return
    end
    local source_line = util.read_line_from_file(filepath, linenumber)
    if not source_line then
        vim.notify("[taskbuffer] could not read source line", vim.log.levels.WARN)
        return
    end
    local new_line, new_date = util.set_date_today_in_string(source_line)
    if new_line then
        if not util.replace_line_in_file(filepath, linenumber, new_line) then
            return
        end
        require("taskbuffer.undo").push({
            op = "set today",
            edits = { { filepath = filepath, linenumber = linenumber, old_line = source_line, new_line = new_line } },
            timestamp = os.time(),
        })
        buffer.refresh_and_restore_cursor()
        vim.notify("[taskbuffer] due: " .. new_date, vim.log.levels.INFO)
        return
    end

    -- Fallback: set frontmatter due date to today
    if cfg.frontmatter and cfg.frontmatter.inherit_due then
        local due_key = cfg.frontmatter.due_key or "due"
        local fm_new_date, fm_line, old_fm_line, new_fm_line = util.set_frontmatter_due_today(filepath, due_key)
        if fm_new_date then
            require("taskbuffer.undo").push({
                op = "set FM today",
                edits = {
                    { filepath = filepath, linenumber = fm_line, old_line = old_fm_line, new_line = new_fm_line },
                },
                timestamp = os.time(),
            })
            buffer.refresh_and_restore_cursor()
            vim.notify("[taskbuffer] FM due: " .. fm_new_date, vim.log.levels.INFO)
            return
        end
    end

    vim.notify("[taskbuffer] no date found on this line", vim.log.levels.WARN)
end

local function set_date_today_in_markdown()
    local cfg = get_config()
    local line = vim.api.nvim_get_current_line()
    local new_line, new_date = util.set_date_today_in_string(line)
    if new_line then
        vim.api.nvim_set_current_line(new_line)
        vim.notify("[taskbuffer] due: " .. new_date, vim.log.levels.INFO)
        return
    end

    -- Fallback: set frontmatter due date to today, jump cursor to FM line
    if cfg.frontmatter and cfg.frontmatter.inherit_due then
        local filepath = vim.api.nvim_buf_get_name(0)
        local due_key = cfg.frontmatter.due_key or "due"
        local fm_line_num, _, _ = util.find_frontmatter_due_line(filepath, due_key)
        if fm_line_num then
            local fm_new_date = util.set_frontmatter_due_today(filepath, due_key)
            if fm_new_date then
                vim.api.nvim_win_set_cursor(0, { fm_line_num, 0 })
                vim.notify("[taskbuffer] FM due: " .. fm_new_date, vim.log.levels.INFO)
                return
            end
        end
    end

    vim.notify("[taskbuffer] no date found on this line", vim.log.levels.WARN)
end

local function shift_task_date_in_markdown(days)
    local cfg = get_config()
    local line = vim.api.nvim_get_current_line()
    local new_line, new_date = util.shift_date_in_string(line, days)
    if new_line then
        vim.api.nvim_set_current_line(new_line)
        vim.notify("[taskbuffer] due: " .. new_date, vim.log.levels.INFO)
        return
    end

    -- Fallback: shift frontmatter due date, jump cursor to FM line
    if cfg.frontmatter and cfg.frontmatter.inherit_due then
        local filepath = vim.api.nvim_buf_get_name(0)
        local due_key = cfg.frontmatter.due_key or "due"
        local fm_new_date, fm_line_num = util.shift_frontmatter_due(filepath, days, due_key)
        if fm_new_date then
            vim.api.nvim_win_set_cursor(0, { fm_line_num, 0 })
            vim.notify("[taskbuffer] FM due: " .. fm_new_date, vim.log.levels.INFO)
            return
        end
    end

    vim.notify("[taskbuffer] no date found on this line", vim.log.levels.WARN)
end

-- Loaded only by a key action or a matching FileType event.
function M.global_action(verb)
    local in_taskfile = vim.bo.filetype == "taskfile"
    local filepath, linenumber
    if in_taskfile then
        filepath, linenumber = get_task_location_from_taskfile()
    else
        filepath, linenumber = get_task_location_from_current_buffer()
    end
    if filepath and linenumber then
        util.run_task_cmd({ verb, filepath, tostring(linenumber) }, in_taskfile)
    end
end

function M.attach_taskfile()
    map("n", "taskfile", "start_task", function()
        local filepath, linenumber = get_task_location_from_taskfile()
        if not filepath then
            return
        end
        local config = get_config()
        local ctx = require("taskbuffer.context").build_context(config, {})
        local line = util.read_line_from_file(filepath, linenumber)
        local task = line
            and require("taskbuffer.parse").parse_task({ path = filepath, line_number = linenumber, text = line }, ctx)
        if not task then
            vim.notify("[taskbuffer] no checkbox task on this line", vim.log.levels.WARN)
            return
        end
        local ok, err = require("taskbuffer.actions").start(filepath, linenumber, task.body, ctx)
        if not ok then
            vim.notify("[taskbuffer] " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        require("taskbuffer.buffer").refresh_and_restore_cursor()
    end, { buffer = true, desc = "Start task" })

    local function go_to_file()
        local filepath, linenumber = util.parse_taskfile_line(vim.api.nvim_get_current_line())
        if not filepath then
            return
        end
        vim.cmd("edit " .. vim.fn.fnameescape(filepath))
        vim.api.nvim_win_set_cursor(0, { math.min(linenumber, vim.api.nvim_buf_line_count(0)), 0 })
        vim.cmd("normal! zz")
    end

    map("n", "taskfile", "go_to_file", go_to_file, { buffer = true, desc = "Go to task source" })
    vim.keymap.set("n", "<CR>", go_to_file, { buffer = true, desc = "Go to task source" })

    map("n", "taskfile", "irrelevant", function()
        local filepath, linenumber = get_task_location_from_taskfile()
        if filepath then
            util.run_task_cmd({ "irrelevant", filepath, tostring(linenumber) }, true)
        end
    end, { buffer = true })

    map("n", "taskfile", "undo_irrelevant", function()
        local filepath, linenumber = get_task_location_from_taskfile()
        if filepath then
            util.run_task_cmd({ "unset", filepath, tostring(linenumber) }, true)
        end
    end, { buffer = true })

    map("n", "taskfile", "filter_tags", function()
        require("taskbuffer.tags").pick_tags()
    end, { buffer = true, desc = "Filter tasks by tag" })

    map("n", "taskfile", "reset_filters", function()
        local buffer = require("taskbuffer.buffer")
        buffer.clear_tag_filter()
        buffer.set_show_markers(false)
        buffer.set_show_undated(require("taskbuffer.config").values.show_undated)
        buffer.refresh_view()
        vim.notify("[taskbuffer] filters reset", vim.log.levels.INFO)
    end, { buffer = true, desc = "Reset task filters" })

    map("n", "taskfile", "toggle_undated", function()
        local buffer = require("taskbuffer.buffer")
        buffer.set_show_undated(not buffer.get_show_undated())
        buffer.refresh_view()
        vim.notify(
            buffer.get_show_undated() and "[taskbuffer] showing undated tasks" or "[taskbuffer] hiding undated tasks",
            vim.log.levels.INFO
        )
    end, { buffer = true, desc = "Toggle undated tasks" })

    map("n", "taskfile", "toggle_markers", function()
        local buffer = require("taskbuffer.buffer")
        buffer.set_show_markers(not buffer.get_show_markers())
        buffer.refresh_view()
        vim.notify(
            buffer.get_show_markers() and "[taskbuffer] showing markers" or "[taskbuffer] hiding markers",
            vim.log.levels.INFO
        )
    end, { buffer = true, desc = "Toggle junk markers" })

    map("n", "taskfile", "shift_date_back", function()
        shift_task_date_in_taskfile(-vim.v.count1)
    end, { buffer = true, desc = "Shift task date back" })

    map("n", "taskfile", "shift_date_forward", function()
        shift_task_date_in_taskfile(vim.v.count1)
    end, { buffer = true, desc = "Shift task date forward" })

    map("n", "taskfile", "set_date_today", function()
        set_date_today_in_taskfile()
    end, { buffer = true, desc = "Set task date to today" })

    map("v", "taskfile", "set_date_today", function()
        local lines = util.get_visual_lines()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        set_task_dates_today_bulk(lines)
    end, { buffer = true, desc = "Set selected task dates to today" })

    map("v", "taskfile", "shift_date_back", function()
        local count = vim.v.count1
        local lines = util.get_visual_lines()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        shift_task_dates_bulk(lines, -count)
    end, { buffer = true, desc = "Shift selected task dates back" })

    map("v", "taskfile", "shift_date_forward", function()
        local count = vim.v.count1
        local lines = util.get_visual_lines()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        shift_task_dates_bulk(lines, count)
    end, { buffer = true, desc = "Shift selected task dates forward" })

    map("v", "taskfile", "quickfix", function()
        local lines = util.get_visual_lines()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        local qf_list = util.taskfile_lines_to_qf(lines)
        if #qf_list == 0 then
            vim.notify("[taskbuffer] no tasks in selection", vim.log.levels.WARN)
            return
        end
        vim.fn.setqflist(qf_list, "r")
        vim.cmd("copen")
    end, { buffer = true, desc = "Send selected tasks to quickfix" })

    -- Undo/redo keymaps: true = auto-detect, string = use as-is, false = skip
    local undo_key = binding("taskfile", "undo")
    if undo_key == true then
        undo_key = detect_key("undo", "u")
    end
    if undo_key then
        vim.keymap.set("n", undo_key, function()
            require("taskbuffer.undo").undo()
        end, { buffer = true, desc = "Undo last date change" })
    end

    local redo_key = binding("taskfile", "redo")
    if redo_key == true then
        redo_key = detect_key("redo", "<C-r>")
    end
    if redo_key then
        vim.keymap.set("n", redo_key, function()
            require("taskbuffer.undo").redo()
        end, { buffer = true, desc = "Redo last date change" })
    end
end

function M.markdown_action(action)
    if action == "set_date_today" then
        set_date_today_in_markdown()
    else
        shift_task_date_in_markdown(action == "shift_date_back" and -vim.v.count1 or vim.v.count1)
    end
end

function M.attach_markdown()
    map("n", "markdown", "set_date_today", function()
        set_date_today_in_markdown()
    end, { buffer = true, desc = "Set task date to today" })

    map("n", "markdown", "shift_date_back", function()
        shift_task_date_in_markdown(-vim.v.count1)
    end, { buffer = true, desc = "Shift task date back" })

    map("n", "markdown", "shift_date_forward", function()
        shift_task_date_in_markdown(vim.v.count1)
    end, { buffer = true, desc = "Shift task date forward" })
end

function M.setup_keymaps()
    require("taskbuffer.bootstrap").register()
end

return M
