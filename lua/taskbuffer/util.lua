local M = {}

--- Parse a taskfile line into filepath and line number.
---@param line string
---@return string filepath
---@return integer|nil linenumber
function M.parse_taskfile_line(line)
    local filepath = string.sub(line, 1, string.find(line, ":") - 1)
    local second_colon = string.find(line, ":", string.find(line, ":") + 1)
    local linenumber = tonumber(string.sub(line, string.find(line, ":") + 1, second_colon - 1))
    return filepath, linenumber
end

--- Read a specific line from a file on disk.
---@param path string
---@param target integer
---@return string|nil
function M.read_line_from_file(path, target)
    local i = 0
    for l in io.lines(path) do
        i = i + 1
        if i == target then
            return l
        end
    end
    return nil
end

--- Replace a single line in a file on disk.
---@param path string
---@param target_line integer
---@param new_content string
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
---@param path string
---@param target_line integer
---@param suffix string
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

--- Build a Lua pattern + os.date format from the configured date format.
--- Returns: lua_pattern (with captures for date components), strftime format,
--- and the open/close wrapper strings.
---@return string lua_pattern  e.g. "(%d%d%d%d)%-(%d%d)%-(%d%d)"
---@return string strftime     e.g. "%Y-%m-%d"
---@return string open         e.g. "(@[["
---@return string close        e.g. "]]"
local function resolve_date_config()
    local cfg = require("taskbuffer.config").values.formats
    local date_fmt = cfg.date or "%Y-%m-%d"
    local wrapper = cfg.date_wrapper or { "(@[[", "]]", ")" }
    local open = wrapper[1] or "(@[["
    local close = wrapper[2] or "]]"

    -- Build Lua pattern from strftime: replace directives with capture groups,
    -- escape Lua magic chars in literals.
    local lua_magic = "([%.%^%$%(%)%[%]%*%+%-%?%%])"
    local pattern = ""
    local i = 1
    while i <= #date_fmt do
        local ch = date_fmt:sub(i, i)
        if ch == "%" and i < #date_fmt then
            local directive = date_fmt:sub(i + 1, i + 1)
            if directive == "Y" then
                pattern = pattern .. "(%d%d%d%d)"
            elseif directive == "m" or directive == "d" then
                pattern = pattern .. "(%d%d)"
            elseif directive == "F" then
                pattern = pattern .. "(%d%d%d%d)%-(%d%d)%-(%d%d)"
            elseif directive == "%" then
                pattern = pattern .. "%%"
            else
                pattern = pattern .. "%%" .. directive
            end
            i = i + 2
        else
            pattern = pattern .. ch:gsub(lua_magic, "%%%1")
            i = i + 1
        end
    end

    return pattern, date_fmt, open, close
end

--- Parse date components from a date string using the configured format.
--- Returns year, month, day as numbers, or nil if parsing fails.
---@param date_str string
---@return number|nil year
---@return number|nil month
---@return number|nil day
local function parse_date_components(date_str)
    local cfg = require("taskbuffer.config").values.formats
    local date_fmt = cfg.date or "%Y-%m-%d"

    -- Determine capture order from the format string
    local order = {}
    local i = 1
    while i <= #date_fmt do
        local ch = date_fmt:sub(i, i)
        if ch == "%" and i < #date_fmt then
            local d = date_fmt:sub(i + 1, i + 1)
            if d == "Y" then
                order[#order + 1] = "Y"
            elseif d == "m" then
                order[#order + 1] = "m"
            elseif d == "d" then
                order[#order + 1] = "d"
            elseif d == "F" then
                order[#order + 1] = "Y"
                order[#order + 1] = "m"
                order[#order + 1] = "d"
            end
            i = i + 2
        else
            i = i + 1
        end
    end

    local pattern = resolve_date_config()
    local captures = { date_str:match(pattern) }
    if #captures == 0 then
        return nil, nil, nil
    end

    local y, m, d
    for idx, cap in ipairs(captures) do
        local key = order[idx]
        if key == "Y" then
            y = tonumber(cap)
        elseif key == "m" then
            m = tonumber(cap)
        elseif key == "d" then
            d = tonumber(cap)
        end
    end
    return y, m, d
end

--- Shift the due date in a task line string by a number of days.
---@param line string
---@param days integer
---@return string|nil new_line
---@return string|nil new_date
function M.shift_date_in_string(line, days)
    local date_pattern, date_fmt, open, close = resolve_date_config()
    local open_escaped = open:gsub("([%.%^%$%(%)%[%]%*%+%-%?%%])", "%%%1")
    local close_escaped = close:gsub("([%.%^%$%(%)%[%]%*%+%-%?%%])", "%%%1")

    -- Match: everything up to and including the open wrapper, then the date, then close wrapper onward
    local full_pattern = "^(.-" .. open_escaped .. ")" .. date_pattern .. "(" .. close_escaped .. ".*)$"
    local captures = { line:match(full_pattern) }
    if #captures == 0 then
        return nil, nil
    end

    local prefix = captures[1]
    local suffix = captures[#captures]
    -- Extract date components from the middle captures
    local date_captures = {}
    for i = 2, #captures - 1 do
        date_captures[#date_captures + 1] = captures[i]
    end

    -- Parse the date string that was matched
    local matched_date = table.concat(date_captures)
    -- Re-extract from the full match to get the actual date substring
    local date_start = #prefix + 1
    local date_end = #line - #suffix
    local date_str = line:sub(date_start, date_end)

    local y, m, d = parse_date_components(date_str)
    if not y then
        return nil, nil
    end

    local t = os.time({ year = y, month = m, day = d })
    local new_t = t + days * 86400
    local new_date = os.date(date_fmt, new_t)
    return prefix .. new_date .. suffix, new_date
end

--- Replace the due date in a task line string with today's date.
---@param line string
---@return string|nil new_line
---@return string|nil new_date
function M.set_date_today_in_string(line)
    local date_pattern, date_fmt, open, close = resolve_date_config()
    local open_escaped = open:gsub("([%.%^%$%(%)%[%]%*%+%-%?%%])", "%%%1")
    local close_escaped = close:gsub("([%.%^%$%(%)%[%]%*%+%-%?%%])", "%%%1")

    local full_pattern = "^(.-" .. open_escaped .. ")" .. date_pattern .. "(" .. close_escaped .. ".*)$"
    local captures = { line:match(full_pattern) }
    if #captures == 0 then
        return nil, nil
    end

    local prefix = captures[1]
    local suffix = captures[#captures]
    local today = os.date(date_fmt)
    return prefix .. today .. suffix, today
end

--- Get the visual selection as a list of lines.
--- Uses '</'> marks; only valid after visual mode exits.
---@return string[]
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

--- Get visually selected lines using live cursor positions.
--- Works during visual mode (before marks are set).
---@return string[]
function M.get_visual_lines()
    local v_pos = vim.fn.getpos("v")
    local c_pos = vim.fn.getpos(".")
    local s_line = math.min(v_pos[2], c_pos[2])
    local e_line = math.max(v_pos[2], c_pos[2])
    if s_line == 0 or e_line == 0 then
        return {}
    end
    return vim.api.nvim_buf_get_lines(0, s_line - 1, e_line, false)
end

--- Parse taskfile lines into quickfix entries.
---@param lines string[]
---@return table[] qf_list
function M.taskfile_lines_to_qf(lines)
    local qf_list = {}
    for _, line in ipairs(lines) do
        local filename, lnum, _, text = string.match(line, "^(.-):(.-):(.-):(.*)$")
        if filename and lnum then
            table.insert(qf_list, { filename = filename, lnum = tonumber(lnum), text = text })
        end
    end
    return qf_list
end

--- Run a Go binary command and optionally refresh the taskfile buffer.
---@param args string[]
---@param refresh boolean
---@return boolean success
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
        require("taskbuffer.buffer").refresh_and_restore_cursor()
    end
    return true
end

return M
