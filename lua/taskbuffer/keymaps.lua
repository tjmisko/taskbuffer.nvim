local M = {}

local keymaps_registered = false
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

--- Read a specific line from a file on disk.
---@param path string
---@param target integer
---@return string|nil
local function read_line_from_file(path, target)
    local i = 0
    for l in io.lines(path) do
        i = i + 1
        if i == target then
            return l
        end
    end
    return nil
end

--- Bulk-shift due dates for multiple taskfile lines.
--- Groups edits by source file and processes from bottom-up to avoid line drift.
---@param lines string[]
---@param days integer
local function shift_task_dates_bulk(lines, days)
    local buffer = require("taskbuffer.buffer")
    -- Group edits by file: { filepath = { {lnum, new_content}, ... } }
    local edits_by_file = {}
    local shifted = 0
    for _, line in ipairs(lines) do
        local filepath, linenumber = util.parse_taskfile_line(line)
        if filepath and linenumber then
            local source_line = read_line_from_file(filepath, linenumber)
            if source_line then
                local new_line = util.shift_date_in_string(source_line, days)
                if new_line then
                    if not edits_by_file[filepath] then
                        edits_by_file[filepath] = {}
                    end
                    table.insert(edits_by_file[filepath], { linenumber, new_line })
                    shifted = shifted + 1
                end
            end
        end
    end
    if shifted == 0 then
        vim.notify("[taskbuffer] no dated tasks in selection", vim.log.levels.WARN)
        return
    end
    -- Apply edits per file, sorted by line number descending to avoid drift
    for filepath, edits in pairs(edits_by_file) do
        table.sort(edits, function(a, b) return a[1] > b[1] end)
        for _, edit in ipairs(edits) do
            util.replace_line_in_file(filepath, edit[1], edit[2])
        end
    end
    buffer.refresh_and_restore_cursor()
    local direction = days > 0 and "forward" or "back"
    vim.notify("[taskbuffer] shifted " .. shifted .. " task(s) " .. direction .. " " .. math.abs(days) .. " day(s)", vim.log.levels.INFO)
end

--- Get filepath and linenumber from a taskfile line.
local function get_task_location_from_taskfile()
    local line = vim.fn.getline(".")
    return util.parse_taskfile_line(line)
end

local function get_task_location_from_current_buffer()
    local filepath = vim.api.nvim_buf_get_name(0)
    local linenumber = vim.api.nvim_win_get_cursor(0)[1]
    return filepath, linenumber
end

local function shift_task_date_in_taskfile(days)
    local buffer = require("taskbuffer.buffer")
    local line = vim.api.nvim_get_current_line()
    local filepath, linenumber = util.parse_taskfile_line(line)
    if not filepath or not linenumber then
        vim.notify("[taskbuffer] could not parse taskfile line", vim.log.levels.WARN)
        return
    end
    local source_line = read_line_from_file(filepath, linenumber)
    if not source_line then
        vim.notify("[taskbuffer] could not read source line", vim.log.levels.WARN)
        return
    end
    local new_line, new_date = util.shift_date_in_string(source_line, days)
    if not new_line then
        vim.notify("[taskbuffer] no date found on this line", vim.log.levels.WARN)
        return
    end
    util.replace_line_in_file(filepath, linenumber, new_line)
    buffer.refresh_and_restore_cursor()
    vim.notify("[taskbuffer] due: " .. new_date, vim.log.levels.INFO)
end

--- Bulk-set due dates to today for multiple taskfile lines.
---@param lines string[]
local function set_task_dates_today_bulk(lines)
    local buffer = require("taskbuffer.buffer")
    local edits_by_file = {}
    local updated = 0
    for _, line in ipairs(lines) do
        local filepath, linenumber = util.parse_taskfile_line(line)
        if filepath and linenumber then
            local source_line = read_line_from_file(filepath, linenumber)
            if source_line then
                local new_line = util.set_date_today_in_string(source_line)
                if new_line then
                    if not edits_by_file[filepath] then
                        edits_by_file[filepath] = {}
                    end
                    table.insert(edits_by_file[filepath], { linenumber, new_line })
                    updated = updated + 1
                end
            end
        end
    end
    if updated == 0 then
        vim.notify("[taskbuffer] no dated tasks in selection", vim.log.levels.WARN)
        return
    end
    for filepath, edits in pairs(edits_by_file) do
        table.sort(edits, function(a, b) return a[1] > b[1] end)
        for _, edit in ipairs(edits) do
            util.replace_line_in_file(filepath, edit[1], edit[2])
        end
    end
    buffer.refresh_and_restore_cursor()
    vim.notify("[taskbuffer] set " .. updated .. " task(s) to today", vim.log.levels.INFO)
end

local function set_date_today_in_taskfile()
    local buffer = require("taskbuffer.buffer")
    local line = vim.api.nvim_get_current_line()
    local filepath, linenumber = util.parse_taskfile_line(line)
    if not filepath or not linenumber then
        vim.notify("[taskbuffer] could not parse taskfile line", vim.log.levels.WARN)
        return
    end
    local source_line = read_line_from_file(filepath, linenumber)
    if not source_line then
        vim.notify("[taskbuffer] could not read source line", vim.log.levels.WARN)
        return
    end
    local new_line, new_date = util.set_date_today_in_string(source_line)
    if not new_line then
        vim.notify("[taskbuffer] no date found on this line", vim.log.levels.WARN)
        return
    end
    util.replace_line_in_file(filepath, linenumber, new_line)
    buffer.refresh_and_restore_cursor()
    vim.notify("[taskbuffer] due: " .. new_date, vim.log.levels.INFO)
end

local function set_date_today_in_markdown()
    local line = vim.api.nvim_get_current_line()
    local new_line, new_date = util.set_date_today_in_string(line)
    if not new_line then
        vim.notify("[taskbuffer] no date found on this line", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_set_current_line(new_line)
    vim.notify("[taskbuffer] due: " .. new_date, vim.log.levels.INFO)
end

local function shift_task_date_in_markdown(days)
    local line = vim.api.nvim_get_current_line()
    local new_line, new_date = util.shift_date_in_string(line, days)
    if not new_line then
        vim.notify("[taskbuffer] no date found on this line", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_set_current_line(new_line)
    vim.notify("[taskbuffer] due: " .. new_date, vim.log.levels.INFO)
end

function M.setup_keymaps()
    if keymaps_registered then
        return
    end
    keymaps_registered = true

    local augroup = vim.api.nvim_create_augroup("TaskBufferKeymaps", { clear = true })

    -- Global keymaps
    map("n", "global", "note", "o<Tab>- [[<Esc>ma:pu=strftime('%F')<CR>\"aDdd`a\"apa]]: ")

    map("n", "global", "complete", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        util.run_task_cmd({ "complete-at", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    map("n", "global", "defer", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        util.run_task_cmd({ "defer", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    map("n", "global", "check_off", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        util.run_task_cmd({ "check", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    map("n", "global", "irrelevant", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        util.run_task_cmd({ "irrelevant", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    map("n", "global", "undo_irrelevant", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        util.run_task_cmd({ "unset", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    -- Taskfile-specific keymaps
    vim.api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = { "taskfile" },
        callback = function()
            local config = get_config()
            local state_path = config.state_dir .. "/current_task"

            map("n", "taskfile", "start_task", function()
                local f = io.open(state_path, "r")
                if f then
                    f:close()
                    os.execute(config.task_bin .. " stop")
                end
                local line = vim.fn.getline(".")
                local filepath = string.sub(line, 1, string.find(line, ":") - 1)
                local linenumber =
                    string.sub(line, string.find(line, ":") + 1, string.find(line, ":", string.find(line, ":") + 1) - 1)
                local datetime = os.time()
                local function trim(s)
                    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
                end
                local task_content = string.match(line, "^.-|.-|.-|(.*)$")
                task_content = task_content and task_content:match("^(.-)%s*::") or task_content
                if task_content then
                    task_content = trim(task_content)
                end
                local g, err = io.open(state_path, "w")
                if not g then
                    vim.notify("[taskbuffer] failed to write state: " .. err, vim.log.levels.ERROR)
                    return
                end
                g:write(datetime .. "\t" .. task_content .. "\t" .. filepath .. "\t" .. linenumber)
                g:close()
                local start_suffix = " ::start " .. os.date("[[%F]] %R")
                util.append_to_line(filepath, tonumber(linenumber), start_suffix)
            end, { buffer = true, desc = "Start task" })

            local function go_to_file()
                local line = vim.fn.getline(".")
                local filepath = string.sub(line, 1, string.find(line, ":") - 1)
                local linenumber =
                    string.sub(line, string.find(line, ":") + 1, string.find(line, ":", string.find(line, ":") + 1) - 1)
                vim.cmd("e " .. filepath)
                vim.cmd("normal " .. linenumber .. "G")
                vim.cmd("normal zz")
            end

            map("n", "taskfile", "go_to_file", go_to_file, { buffer = true, desc = "Go to task source" })
            vim.keymap.set("n", "<CR>", go_to_file, { buffer = true, desc = "Go to task source" })

            map("n", "taskfile", "irrelevant", function()
                local filepath, linenumber = get_task_location_from_taskfile()
                util.run_task_cmd({ "irrelevant", filepath, tostring(linenumber) }, true)
            end, { buffer = true })

            map("n", "taskfile", "undo_irrelevant", function()
                local filepath, linenumber = get_task_location_from_taskfile()
                util.run_task_cmd({ "unset", filepath, tostring(linenumber) }, true)
            end, { buffer = true })

            map("n", "taskfile", "partial", function()
                local filepath, linenumber = get_task_location_from_taskfile()
                util.run_task_cmd({ "partial", filepath, tostring(linenumber) }, true)
            end, { buffer = true })

            map("n", "taskfile", "filter_tags", function()
                require("taskbuffer.tags").pick_tags()
            end, { buffer = true, desc = "Filter tasks by tag" })

            map("n", "taskfile", "reset_filters", function()
                local buffer = require("taskbuffer.buffer")
                buffer.clear_tag_filter()
                buffer.set_show_markers(false)
                buffer.set_show_undated(require("taskbuffer.config").values.show_undated)
                buffer.refresh_and_restore_cursor()
                vim.notify("[taskbuffer] filters reset", vim.log.levels.INFO)
            end, { buffer = true, desc = "Reset task filters" })

            map("n", "taskfile", "toggle_undated", function()
                local buffer = require("taskbuffer.buffer")
                buffer.set_show_undated(not buffer.get_show_undated())
                buffer.refresh_and_restore_cursor()
                vim.notify(
                    buffer.get_show_undated() and "[taskbuffer] showing undated tasks"
                        or "[taskbuffer] hiding undated tasks",
                    vim.log.levels.INFO
                )
            end, { buffer = true, desc = "Toggle undated tasks" })

            map("n", "taskfile", "toggle_markers", function()
                local buffer = require("taskbuffer.buffer")
                buffer.set_show_markers(not buffer.get_show_markers())
                buffer.refresh_and_restore_cursor()
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
        end,
    })

    -- Markdown date shift keymaps
    vim.api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = { "markdown" },
        callback = function()
            map("n", "markdown", "set_date_today", function()
                set_date_today_in_markdown()
            end, { buffer = true, desc = "Set task date to today" })

            map("n", "markdown", "shift_date_back", function()
                shift_task_date_in_markdown(-vim.v.count1)
            end, { buffer = true, desc = "Shift task date back" })

            map("n", "markdown", "shift_date_forward", function()
                shift_task_date_in_markdown(vim.v.count1)
            end, { buffer = true, desc = "Shift task date forward" })
        end,
    })
end

return M
