local M = {}

--- Parse a taskfile line into filepath and line number.
function M.parse_taskfile_line(line)
    local filepath = string.sub(line, 1, string.find(line, ":") - 1)
    local second_colon = string.find(line, ":", string.find(line, ":") + 1)
    local linenumber = tonumber(string.sub(line, string.find(line, ":") + 1, second_colon - 1))
    return filepath, linenumber
end

--- Replace a single line in a file on disk.
function M.replace_line_in_file(path, target_line, new_content)
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
    local f, err = io.open(path, "w")
    if not f then
        vim.notify("[taskbuffer] failed to write file: " .. err, vim.log.levels.ERROR)
        return
    end
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
end

--- Append a suffix to a specific line in a file on disk.
function M.append_to_line(path, target_line, suffix)
    local lines = {}
    local i = 0
    for line in io.lines(path) do
        i = i + 1
        if i == target_line then
            line = line .. suffix
        end
        lines[#lines + 1] = line
    end
    local f, err = io.open(path, "w")
    if not f then
        vim.notify("[taskbuffer] failed to write file: " .. err, vim.log.levels.ERROR)
        return
    end
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
end

--- Shift the due date in a task line string by a number of days.
function M.shift_date_in_string(line, days)
    local prefix, y, m, d, suffix = line:match("^(.-%(@%[%[)(%d%d%d%d)%-(%d%d)%-(%d%d)(%]%].*)$")
    if not y then
        return nil, nil
    end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
    local new_t = t + days * 86400
    local new_date = os.date("%Y-%m-%d", new_t)
    return prefix .. new_date .. suffix, new_date
end

--- Get the visual selection as a list of lines.
function M.get_visual_selection()
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

--- Run a Go binary command and optionally refresh the taskfile buffer.
function M.run_task_cmd(args, refresh)
    local config = require("taskbuffer.config").values
    local cmd = { config.task_bin }
    for _, a in ipairs(args) do
        table.insert(cmd, a)
    end
    local result = vim.system(cmd, { text = true }):wait()
    if result.code ~= 0 then
        vim.notify("[taskbuffer] task command failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
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

return M
