-- state.lua — current_task state file + canonical marker formatter
-- (port of go/state.go).
--
-- These are pure primitives: the state directory is passed in (the actions /
-- config layer resolves it from config.values.state_dir and ~-expansion). They
-- do NOT read config or the wall clock.
--
-- The current_task file format is BYTE-IDENTICAL to Go's (state.go:83): a single
-- TSV line `<start_time>\t<name>\t<filepath>\t<linenumber>\n` (with trailing
-- newline). This file is consumed by start/stop logic and must not change.

local strftime = require("taskbuffer.strftime")

local M = {}

local STATE_FILE = "current_task"

---@class CurrentTask
---@field start_time integer  -- unix seconds
---@field name string         -- task body
---@field filepath string
---@field linenumber integer

-- statePathFor (state.go:32). `state_dir` is already ~-expanded by the config
-- layer; here we just join the state filename onto it.
---@param state_dir string
---@return string
function M.state_path(state_dir)
    return vim.fs.joinpath(state_dir, STATE_FILE)
end

-- SplitN-equivalent on TAB into at most `n` parts, the last part being the
-- unsplit remainder (mirrors Go's strings.SplitN(line, "\t", 4)).
local function splitn_tab(s, n)
    local parts = {}
    local start = 1
    while #parts < n - 1 do
        local i = s:find("\t", start, true)
        if not i then
            break
        end
        parts[#parts + 1] = s:sub(start, i - 1)
        start = i + 1
    end
    parts[#parts + 1] = s:sub(start)
    return parts
end

-- ReadCurrentTaskFrom (state.go:45). Missing file -> nil,nil. Malformed -> nil,err.
---@param state_dir string
---@return CurrentTask|nil, string|nil
function M.read_current_task(state_dir)
    local path = M.state_path(state_dir)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return nil, nil -- no file (os.IsNotExist -> nil,nil)
    end
    local f = io.open(path, "rb")
    if not f then
        return nil, "reading " .. path
    end
    local data = f:read("*a") or ""
    f:close()

    -- TrimRight(data, "\n\r") (state.go:53).
    local line = (data:gsub("[\n\r]+$", ""))
    local parts = splitn_tab(line, 4)
    if #parts < 4 then
        return nil, string.format("malformed current_task: %q", line)
    end
    local ts = tonumber(parts[1])
    if not ts then
        return nil, "bad timestamp: " .. parts[1]
    end
    local ln = tonumber(parts[4])
    if not ln then
        return nil, "bad line number: " .. parts[4]
    end
    return {
        start_time = math.floor(ts),
        name = parts[2],
        filepath = parts[3],
        linenumber = math.floor(ln),
    }
end

-- WriteCurrentTaskTo (state.go:78). mkdir -p the state dir, then write the TSV
-- line with a trailing newline.
---@param state_dir string
---@param ct CurrentTask
---@return boolean ok, string|nil err
function M.write_current_task(state_dir, ct)
    vim.fn.mkdir(state_dir, "p")
    local line = string.format("%d\t%s\t%s\t%d\n", ct.start_time, ct.name, ct.filepath, ct.linenumber)
    local f = io.open(M.state_path(state_dir), "wb")
    if not f then
        return false, "writing " .. M.state_path(state_dir)
    end
    f:write(line)
    f:close()
    return true
end

-- ClearCurrentTaskFrom (state.go:91). Remove the file; missing -> ok (no error).
---@param state_dir string
---@return boolean ok, string|nil err
function M.clear_current_task(state_dir)
    local path = M.state_path(state_dir)
    if not vim.uv.fs_stat(path) then
        return true -- already gone (os.IsNotExist -> nil)
    end
    local ok, err = os.remove(path)
    if not ok then
        return false, err
    end
    return true
end

-- FormatMarker (state.go:99). Canonical marker formatter. Produces
-- `<prefix><kind> [[DATE]] TIME ` (note the TRAILING space).
--
-- `now_epoch` is injected (no internal clock read) for deterministic tests.
-- `ctx` is a plain table read for { date_fmt, time_fmt, marker_prefix }. Per
-- overview D8 the CONFIGURED marker_prefix is used (Go hardcoded "::"); the
-- default "::" is byte-identical to Go.
---@param kind string
---@param now_epoch integer
---@param ctx { date_fmt:string, time_fmt:string, marker_prefix:string }
---@return string
function M.format_marker(kind, now_epoch, ctx)
    local prefix = ctx.marker_prefix or "::"
    local date = strftime.format_epoch(now_epoch, ctx.date_fmt)
    local time = strftime.format_epoch(now_epoch, ctx.time_fmt)
    return prefix .. kind .. " [[" .. date .. "]] " .. time .. " "
end

return M
