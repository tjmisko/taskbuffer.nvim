local M = {}

local keymaps_registered = false

local function get_config()
    return require("taskbuffer").config
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

local function parse_taskfile_line(line)
    local filepath = string.sub(line, 1, string.find(line, ":") - 1)
    local second_colon = string.find(line, ":", string.find(line, ":") + 1)
    local linenumber = tonumber(string.sub(line, string.find(line, ":") + 1, second_colon - 1))
    return filepath, linenumber
end

local function replace_line_in_file(path, target_line, new_content)
    local lines = {}
    local i = 0
    for line in io.lines(path) do
        i = i + 1
        if i == target_line then
            lines[#lines + 1] = new_content
        else
            lines[#lines + 1] = line
        end
    end
    local f = assert(io.open(path, "w"))
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
end

local function append_to_line(path, target_line, suffix)
    local lines = {}
    local i = 0
    for line in io.lines(path) do
        i = i + 1
        if i == target_line then
            line = line .. suffix
        end
        lines[#lines + 1] = line
    end
    local f = assert(io.open(path, "w"))
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
end

local function shift_date_in_string(line, days)
    local prefix, y, m, d, suffix = line:match("^(.-%(@%[%[)(%d%d%d%d)%-(%d%d)%-(%d%d)(%]%].*)$")
    if not y then
        return nil, nil
    end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
    local new_t = t + days * 86400
    local new_date = os.date("%Y-%m-%d", new_t)
    return prefix .. new_date .. suffix, new_date
end

local function get_visual_selection()
    local s_mark = vim.api.nvim_buf_get_mark(0, "<")
    local e_mark = vim.api.nvim_buf_get_mark(0, ">")
    local s_line, s_col = s_mark[1], s_mark[2]
    local e_line, e_col = e_mark[1], e_mark[2]

    if s_line == 0 or e_line == 0 then
        return {}
    end

    if s_line == e_line then
        local line_text = vim.api.nvim_buf_get_lines(0, s_line - 1, s_line, false)[1]
        return { line_text:sub(s_col, e_col) }
    end

    local lines = vim.api.nvim_buf_get_lines(0, s_line - 1, e_line, false)
    if #lines == 0 then
        return {}
    end

    lines[1] = lines[1]:sub(s_col)
    lines[#lines] = lines[#lines]:sub(1, e_col)
    return lines
end

local function set_quickfix_task_list()
    local lines = get_visual_selection()
    local qf_list = {}
    for _, line in ipairs(lines) do
        local filename, lnum, _, text = string.match(line, "^(.-):(.-):(.-):(.*)$")
        local qf_line = { filename = filename, lnum = lnum, text = text }
        table.insert(qf_list, qf_line)
    end
    vim.fn.setqflist(qf_list, "r")
    vim.cmd("copen")
end

--- Run a Go binary command and optionally refresh the taskfile buffer.
local function run_task_cmd(args, refresh)
    local config = get_config()
    local cmd = { config.task_bin }
    for _, a in ipairs(args) do
        table.insert(cmd, a)
    end
    local result = vim.system(cmd, { text = true }):wait()
    if result.code ~= 0 then
        vim.notify("task command failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
        return false
    end
    if refresh then
        local buffer = require("taskbuffer.buffer")
        local cursor = vim.api.nvim_win_get_cursor(0)
        buffer.set_refreshing(true)
        buffer.refresh_taskfile()
        vim.cmd("edit!")
        vim.bo.readonly = true
        buffer.set_refreshing(false)
        pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    end
    return true
end

--- Get filepath and linenumber from a taskfile line or current markdown buffer.
local function get_task_location_from_taskfile()
    local line = vim.fn.getline(".")
    return parse_taskfile_line(line)
end

local function get_task_location_from_current_buffer()
    local filepath = vim.api.nvim_buf_get_name(0)
    local linenumber = vim.api.nvim_win_get_cursor(0)[1]
    return filepath, linenumber
end

local function shift_task_date_in_taskfile(days)
    local buffer = require("taskbuffer.buffer")
    local line = vim.api.nvim_get_current_line()
    local filepath, linenumber = parse_taskfile_line(line)
    if not filepath or not linenumber then
        vim.notify("Could not parse taskfile line", vim.log.levels.WARN)
        return
    end
    local i = 0
    local source_line
    for l in io.lines(filepath) do
        i = i + 1
        if i == linenumber then
            source_line = l
            break
        end
    end
    if not source_line then
        vim.notify("Could not read source line", vim.log.levels.WARN)
        return
    end
    local new_line, new_date = shift_date_in_string(source_line, days)
    if not new_line then
        vim.notify("No date found on this line", vim.log.levels.WARN)
        return
    end
    replace_line_in_file(filepath, linenumber, new_line)
    local cursor = vim.api.nvim_win_get_cursor(0)
    buffer.set_refreshing(true)
    buffer.refresh_taskfile()
    vim.cmd("edit!")
    vim.bo.readonly = true
    buffer.set_refreshing(false)
    pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    vim.notify("Due: " .. new_date, vim.log.levels.INFO)
end

local function shift_task_date_in_markdown(days)
    local line = vim.api.nvim_get_current_line()
    local new_line, new_date = shift_date_in_string(line, days)
    if not new_line then
        vim.notify("No date found on this line", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_set_current_line(new_line)
    vim.notify("Due: " .. new_date, vim.log.levels.INFO)
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
        run_task_cmd({ "complete-at", filepath, tostring(linenumber) }, false)
        -- Re-read the line since the Go binary modified the file
        vim.cmd("edit!")
    end)

    map("n", "global", "defer", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        run_task_cmd({ "defer", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    map("n", "global", "check_off", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        run_task_cmd({ "check", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    map("n", "global", "irrelevant", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        run_task_cmd({ "irrelevant", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    map("n", "global", "undo_irrelevant", function()
        local filepath, linenumber = get_task_location_from_current_buffer()
        run_task_cmd({ "unset", filepath, tostring(linenumber) }, false)
        vim.cmd("edit!")
    end)

    map({ "n", "v" }, "global", "quickfix", set_quickfix_task_list)

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
                local g = assert(io.open(state_path, "w"))
                g:write(datetime .. "\t" .. task_content .. "\t" .. filepath .. "\t" .. linenumber)
                g:close()
                local start_suffix = " ::start " .. os.date("[[%F]] %R")
                append_to_line(filepath, tonumber(linenumber), start_suffix)
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
                run_task_cmd({ "irrelevant", filepath, tostring(linenumber) }, true)
            end, { buffer = true })

            map("n", "taskfile", "undo_irrelevant", function()
                local filepath, linenumber = get_task_location_from_taskfile()
                run_task_cmd({ "unset", filepath, tostring(linenumber) }, true)
            end, { buffer = true })

            map("n", "taskfile", "partial", function()
                local filepath, linenumber = get_task_location_from_taskfile()
                run_task_cmd({ "partial", filepath, tostring(linenumber) }, true)
            end, { buffer = true })

            map("n", "taskfile", "filter_tags", function()
                require("taskbuffer.tags").pick_tags()
            end, { buffer = true, desc = "Filter tasks by tag" })

            map("n", "taskfile", "reset_filters", function()
                local buffer = require("taskbuffer.buffer")
                buffer.clear_tag_filter()
                buffer.set_show_markers(false)
                buffer.set_show_undated(require("taskbuffer").config.show_undated)
                buffer.set_refreshing(true)
                buffer.refresh_taskfile()
                vim.cmd("edit!")
                vim.bo.readonly = true
                buffer.set_refreshing(false)
                vim.notify("Filters reset", vim.log.levels.INFO)
            end, { buffer = true, desc = "Reset task filters" })

            map("n", "taskfile", "toggle_undated", function()
                local buffer = require("taskbuffer.buffer")
                buffer.set_show_undated(not buffer.get_show_undated())
                buffer.set_refreshing(true)
                buffer.refresh_taskfile()
                vim.cmd("edit!")
                vim.bo.readonly = true
                buffer.set_refreshing(false)
                vim.notify(
                    buffer.get_show_undated() and "Showing undated tasks" or "Hiding undated tasks",
                    vim.log.levels.INFO
                )
            end, { buffer = true, desc = "Toggle undated tasks" })

            map("n", "taskfile", "toggle_markers", function()
                local buffer = require("taskbuffer.buffer")
                buffer.set_show_markers(not buffer.get_show_markers())
                buffer.set_refreshing(true)
                buffer.refresh_taskfile()
                vim.cmd("edit!")
                vim.bo.readonly = true
                buffer.set_refreshing(false)
                vim.notify(buffer.get_show_markers() and "Showing markers" or "Hiding markers", vim.log.levels.INFO)
            end, { buffer = true, desc = "Toggle junk markers" })

            map("n", "taskfile", "shift_date_back", function()
                shift_task_date_in_taskfile(-vim.v.count1)
            end, { buffer = true, desc = "Shift task date back" })

            map("n", "taskfile", "shift_date_forward", function()
                shift_task_date_in_taskfile(vim.v.count1)
            end, { buffer = true, desc = "Shift task date forward" })
        end,
    })

    -- Markdown date shift keymaps
    vim.api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = { "markdown" },
        callback = function()
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
