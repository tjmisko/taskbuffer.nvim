local M = {}

--- Parse the location prefix; headings and blank lines are not tasks.
function M.parse_taskfile_line(line)
    local path, lnum = line:match("^(.-):(%d+):%d+:")
    if not path or path == "" or tonumber(lnum) < 1 then
        return nil, nil
    end
    return path, tonumber(lnum)
end

local function read_lines(path)
    local data = require("taskbuffer.source").read(path)
    return data and vim.split(data, "\n", { plain = true })
end

function M.read_line_from_file(path, target)
    local lines = read_lines(path)
    local line = lines and lines[target]
    return line and (line:gsub("\r$", ""))
end

function M.check_source(path)
    local ok, err = require("taskbuffer.source").check(path)
    if not ok then
        vim.notify("[taskbuffer] " .. err, vim.log.levels.WARN)
    end
    return ok
end

-- Reject stale task locations and unsaved source buffers before any mutation.
function M.taskfile_location(line)
    local path, lnum = M.parse_taskfile_line(line)
    if not path or not M.check_source(path) then
        return nil, nil
    end
    local buffer = require("taskbuffer.buffer")
    if buffer.validate_source and not buffer.validate_source(path, lnum) then
        return nil, nil
    end
    return path, lnum
end

function M.replace_line_in_file(path, target, content)
    local lines = read_lines(path)
    if not lines or not lines[target] then
        vim.notify("[taskbuffer] source line not found: " .. path, vim.log.levels.WARN)
        return false
    end
    if lines[target]:sub(-1) == "\r" and content:sub(-1) ~= "\r" then
        content = content .. "\r"
    end
    lines[target] = content
    local ok, err = require("taskbuffer.source").write(path, table.concat(lines, "\n"))
    if not ok then
        vim.notify("[taskbuffer] " .. tostring(err), vim.log.levels.ERROR)
    end
    return ok
end

function M.append_to_line(path, target, suffix)
    local line = M.read_line_from_file(path, target)
    if not line then
        vim.notify("[taskbuffer] source line not found: " .. path, vim.log.levels.WARN)
        return false
    end
    return M.replace_line_in_file(path, target, line .. suffix)
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

--- Find the frontmatter due date line in a file.
--- Scans for `<due_key>:` between `---` delimiters.
---@param path string
---@param due_key string
---@return integer|nil line_number
---@return string|nil current_value (the date portion)
---@return boolean is_quoted
function M.find_frontmatter_due_line(path, due_key)
    local lines = read_lines(path)
    if not lines then
        return nil, nil, false
    end
    local in_fm = false
    local i = 0
    for _, raw in ipairs(lines) do
        local line = raw:gsub("\r$", "")
        i = i + 1
        if i == 1 then
            if line:match("^%-%-%-$") then
                in_fm = true
            else
                return nil, nil, false
            end
        elseif in_fm then
            if line:match("^%-%-%-$") then
                return nil, nil, false
            end
            local key, value = line:match("^(" .. vim.pesc(due_key) .. "):%s*(.*)$")
            if key then
                local quoted = false
                local date_val = value
                -- Strip quotes if present
                local q = value:match('^"(.*)"$') or value:match("^'(.*)'$")
                if q then
                    quoted = true
                    date_val = q
                end
                return i, date_val, quoted
            end
        end
    end
    return nil, nil, false
end

--- Shift the frontmatter due date in a file by a number of days.
---@param path string
---@param days integer
---@param due_key string
---@return string|nil new_date
---@return integer|nil line_number
---@return string|nil old_line
---@return string|nil new_line
function M.shift_frontmatter_due(path, days, due_key)
    local line_num, date_val, is_quoted = M.find_frontmatter_due_line(path, due_key)
    if not line_num or not date_val or date_val == "" then
        return nil, nil, nil, nil
    end

    -- Parse date (just the date portion, ignore time)
    local date_part = date_val:match("^(%S+)")
    if not date_part then
        return nil, nil, nil, nil
    end

    local y, m, d = parse_date_components(date_part)
    if not y then
        return nil, nil, nil, nil
    end

    local cfg = require("taskbuffer.config").values.formats
    local date_fmt = cfg.date or "%Y-%m-%d"
    local t = os.time({ year = y, month = m, day = d })
    local new_t = t + days * 86400
    local new_date = os.date(date_fmt, new_t)

    -- Reconstruct time portion if present
    local time_part = date_val:match("^%S+%s+(.+)$")
    local new_val = new_date
    if time_part then
        new_val = new_date .. " " .. time_part
    end

    local old_full_line = M.read_line_from_file(path, line_num)
    local new_full_line
    if is_quoted then
        new_full_line = due_key .. ': "' .. new_val .. '"'
    else
        new_full_line = due_key .. ": " .. new_val
    end

    if not M.replace_line_in_file(path, line_num, new_full_line) then
        return nil
    end
    return new_date, line_num, old_full_line, new_full_line
end

--- Set the frontmatter due date to today.
---@param path string
---@param due_key string
---@return string|nil new_date
---@return integer|nil line_number
---@return string|nil old_line
---@return string|nil new_line
function M.set_frontmatter_due_today(path, due_key)
    local line_num, date_val, is_quoted = M.find_frontmatter_due_line(path, due_key)
    if not line_num or not date_val or date_val == "" then
        return nil, nil, nil, nil
    end

    local cfg = require("taskbuffer.config").values.formats
    local date_fmt = cfg.date or "%Y-%m-%d"
    local today = os.date(date_fmt)

    -- Preserve time portion if present
    local time_part = date_val:match("^%S+%s+(.+)$")
    local new_val = today
    if time_part then
        new_val = today .. " " .. time_part
    end

    local old_full_line = M.read_line_from_file(path, line_num)
    local new_full_line
    if is_quoted then
        new_full_line = due_key .. ': "' .. new_val .. '"'
    else
        new_full_line = due_key .. ": " .. new_val
    end

    if not M.replace_line_in_file(path, line_num, new_full_line) then
        return nil
    end
    return today, line_num, old_full_line, new_full_line
end

--- Parse taskfile lines into quickfix entries.
---@param lines string[]
---@return table[] qf_list
function M.taskfile_lines_to_qf(lines)
    local qf_list = {}
    for _, line in ipairs(lines) do
        local filename, lnum, text = string.match(line, "^(.-):(%d+):%d+:(.*)$")
        if filename and lnum then
            table.insert(qf_list, { filename = filename, lnum = tonumber(lnum), text = text })
        end
    end
    return qf_list
end

--- Run a task action and optionally refresh the taskfile buffer.
---@param args string[]
---@param refresh boolean
---@return boolean success
-- Maps the verb (args[1]) to the actions.lua method. All five verbs share the
-- (path, lnum, ctx) signature; defaults are applied inside actions.
local VERB_TO_ACTION = {
    ["complete-at"] = "complete_at",
    ["defer"] = "defer",
    ["check"] = "check",
    ["irrelevant"] = "irrelevant",
    ["unset"] = "unset",
}

function M.run_task_cmd(args, refresh)
    local config = require("taskbuffer.config").values

    local method = VERB_TO_ACTION[args[1]]
    if not method then
        vim.notify("[taskbuffer] unknown action: " .. tostring(args[1]), vim.log.levels.ERROR)
        return false
    end
    if not args[2] or not tonumber(args[3]) or not M.check_source(args[2]) then
        return false
    end
    local ctx = require("taskbuffer.context").build_context(config, {})
    local line = M.read_line_from_file(args[2], tonumber(args[3]))
    if
        not line
        or not require("taskbuffer.parse").parse_task(
            { path = args[2], line_number = tonumber(args[3]), text = line },
            ctx
        )
    then
        vim.notify("[taskbuffer] no task on this source line", vim.log.levels.WARN)
        return false
    end
    local ok, err = require("taskbuffer.actions")[method](args[2], tonumber(args[3]), ctx)
    if not ok then
        vim.notify("[taskbuffer] task command failed: " .. tostring(err), vim.log.levels.ERROR)
        return false
    end
    if refresh then
        require("taskbuffer.buffer").refresh_and_restore_cursor()
    end
    return true
end

return M
