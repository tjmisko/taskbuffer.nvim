-- mutate.lua — file-line mutation primitives (port of go/mutate.go).
--
-- Phase-1 parity: these operate on FILE BYTES (read whole file -> modify lines
-- -> write whole file), exactly like mutate.go, so output is byte-for-byte
-- comparable to Go. The buffer-aware safety path (overview D9) is a LATER
-- actions-layer concern and is deliberately NOT implemented here.
--
-- Newline fidelity (overview D10): we mirror Go's strings.Split("\n") /
-- strings.Join("\n") exactly. vim.split(data, "\n", {plain=true}) keeps the
-- trailing empty element for a file ending in "\n" (just like Split), and
-- table.concat(lines, "\n") restores it (just like Join). So a file WITHOUT a
-- trailing newline stays without one, and CRLF "\r" is preserved verbatim
-- (TrimRight only strips " \t", never "\r", matching Go).
--
-- All functions return `ok:boolean, err:string|nil` (mirrors Go's error return).

local strftime = require("taskbuffer.strftime")

local M = {}

-- Escape a literal string for use inside a Lua pattern.
-- Magic chars in Lua patterns: ^$()%.[]*+-?
local function pesc(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Read the whole file as bytes. Returns nil on any open failure (caller
-- distinguishes "missing -> create" from "missing -> error").
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a") or ""
    f:close()
    return data
end

-- Read file and split into lines exactly like Go's strings.Split(data, "\n").
-- Returns nil if the file cannot be opened.
local function read_lines(path)
    local data = read_file(path)
    if data == nil then
        return nil
    end
    return vim.split(data, "\n", { plain = true })
end

-- Write a raw byte string, overwriting the file.
local function write_string(path, data)
    local f = io.open(path, "wb")
    if not f then
        return false, "writing " .. path
    end
    f:write(data)
    f:close()
    return true
end

-- Write lines back exactly like Go's strings.Join(lines, "\n").
local function write_lines(path, lines)
    return write_string(path, table.concat(lines, "\n"))
end

-- Trim trailing spaces/tabs (Go's strings.TrimRight(line, " \t")). Note: does
-- NOT strip "\r", matching Go (CRLF parity, D10).
local function trim_right_ws(line)
    return (line:gsub("[ \t]+$", ""))
end

local function out_of_range(lnum, n)
    return string.format("line %d out of range (file has %d lines)", lnum, n)
end

-- AppendToLine (mutate.go:11). Trims trailing whitespace of the target line,
-- then appends " " .. text. `text` is the already-formatted marker (which may
-- itself end in a space — that trailing space is preserved).
---@param path string
---@param lnum integer
---@param text string
---@return boolean ok, string|nil err
function M.append_to_line(path, lnum, text)
    local lines = read_lines(path)
    if not lines then
        return false, "reading " .. path
    end
    if lnum < 1 or lnum > #lines then
        return false, out_of_range(lnum, #lines)
    end
    lines[lnum] = trim_right_ws(lines[lnum]) .. " " .. text
    return write_lines(path, lines)
end

-- ChangeCheckbox (mutate.go:36). Replaces the FIRST occurrence of `from` with
-- `to` on the line, treating both as literals (they contain "[" "]"). Empty
-- `from`/`to` is an error (mutate.go:37-42). Absent `from` is a no-op that still
-- rewrites the (unchanged) file, matching Go's strings.Replace(...,1).
---@param path string
---@param lnum integer
---@param from string
---@param to string
---@return boolean ok, string|nil err
function M.change_checkbox(path, lnum, from, to)
    if from == "" then
        return false, "ChangeCheckbox: empty 'from' checkbox string"
    end
    if to == "" then
        return false, "ChangeCheckbox: empty 'to' checkbox string"
    end
    local lines = read_lines(path)
    if not lines then
        return false, "reading " .. path
    end
    if lnum < 1 or lnum > #lines then
        return false, out_of_range(lnum, #lines)
    end
    local line = lines[lnum]
    local s, e = line:find(from, 1, true) -- plain find: positional, indentation-preserving
    if s then
        lines[lnum] = line:sub(1, s - 1) .. to .. line:sub(e + 1)
    end
    return write_lines(path, lines)
end

-- CheckOffTaskWith (mutate.go:31). Change the checkbox from `open_cb` to `done_cb`.
---@param path string
---@param lnum integer
---@param open_cb string
---@param done_cb string
---@return boolean ok, string|nil err
function M.check_off_task_with(path, lnum, open_cb, done_cb)
    return M.change_checkbox(path, lnum, open_cb, done_cb)
end

-- CheckOffTask (mutate.go:26). Change "- [ ]" -> "- [x]" (default checkboxes).
---@param path string
---@param lnum integer
---@return boolean ok, string|nil err
function M.check_off_task(path, lnum)
    return M.change_checkbox(path, lnum, "- [ ]", "- [x]")
end

-- RemoveLastMarker (mutate.go:57). Removes the LAST occurrence of
-- `<marker_prefix><kind> [[DATE]] [TIME]` from the line (time optional). No-op
-- (ok=true) if no marker is present. Date/time patterns come from the single
-- strftime.lua source (the .run fragment of each compiled format), and we track
-- match spans in pure Lua (overview §3.2 prefers this over vim.regex).
--
-- The base pattern requires `<marker_prefix><kind>` directly, so an inline due
-- `(@[[...]])` is never matched.
---@param path string
---@param lnum integer
---@param kind string
---@param date_fmt string|nil  -- defaults to "%Y-%m-%d"
---@param time_fmt string|nil  -- defaults to "%H:%M"
---@param marker_prefix string|nil  -- defaults to "::" (Go hardcodes "::"; D8 uses configured prefix)
---@return boolean ok, string|nil err
function M.remove_last_marker(path, lnum, kind, date_fmt, time_fmt, marker_prefix)
    date_fmt = date_fmt or "%Y-%m-%d"
    time_fmt = time_fmt or "%H:%M"
    marker_prefix = marker_prefix or "::"

    local lines = read_lines(path)
    if not lines then
        return false, "reading " .. path
    end
    if lnum < 1 or lnum > #lines then
        return false, out_of_range(lnum, #lines)
    end

    local date_run = strftime.compile(date_fmt).run
    local time_run = strftime.compile(time_fmt).run

    -- Base = \s*<prefix><kind>\s+[[DATE]] ; the trailing \s*(TIME)? is handled
    -- by greedily extending each base match below (Lua patterns have no optional
    -- group). Mirrors mutate.go:69's `\s*::%s\s+\[\[%s\]\]\s*(%s)?`.
    local base = "%s*" .. pesc(marker_prefix) .. pesc(kind) .. "%s+%[%[" .. date_run .. "%]%]"

    local line = lines[lnum]
    local last_s, last_e
    local pos = 1
    while true do
        local s, eb = line:find(base, pos)
        if not s then
            break
        end
        -- Consume \s* after the closing ]] then optionally a TIME (Go's
        -- \s*(TIME)?: the whitespace is consumed greedily even when no time
        -- follows; if a time follows it is included).
        local rest = line:sub(eb + 1)
        local ws = rest:match("^%s*") or ""
        local e = eb + #ws
        local tm = rest:sub(#ws + 1):match("^" .. time_run)
        if tm then
            e = e + #tm
        end
        last_s, last_e = s, e
        pos = e + 1
        if pos <= s then -- zero-width guard (shouldn't happen: base is non-empty)
            pos = s + 1
        end
    end

    if not last_s then
        return true -- no marker to remove (mutate.go:74)
    end

    line = line:sub(1, last_s - 1) .. line:sub(last_e + 1)
    line = trim_right_ws(line) -- mutate.go:80
    lines[lnum] = line
    return write_lines(path, lines)
end

-- InsertAfterHeader (mutate.go:87). Insert `text` on the line after a header
-- (TrimSpace equality). Header-not-found -> ensure a trailing newline then
-- append "\n" + header + "\n" + text + "\n". File-missing -> create with
-- header + "\n" + text + "\n".
---@param path string
---@param header string
---@param text string
---@return boolean ok, string|nil err
function M.insert_after_header(path, header, text)
    local data = read_file(path)
    if data == nil then
        return write_string(path, header .. "\n" .. text .. "\n")
    end

    local lines = vim.split(data, "\n", { plain = true })
    local target = vim.trim(header)
    local header_idx
    for i, line in ipairs(lines) do
        if vim.trim(line) == target then
            header_idx = i
            break
        end
    end

    if not header_idx then
        local content = data
        if content:sub(-1) ~= "\n" then
            content = content .. "\n"
        end
        content = content .. "\n" .. header .. "\n" .. text .. "\n"
        return write_string(path, content)
    end

    table.insert(lines, header_idx + 1, text)
    return write_lines(path, lines)
end

-- AppendToFile (mutate.go:126). Append `text` + "\n", creating the file if
-- missing. Preserves the file's existing trailing-newline state.
---@param path string
---@param text string
---@return boolean ok, string|nil err
function M.append_to_file(path, text)
    local data = read_file(path)
    if data == nil then
        return write_string(path, text .. "\n")
    end
    local content = data
    if content:sub(-1) ~= "\n" then
        content = content .. "\n"
    end
    content = content .. text .. "\n"
    return write_string(path, content)
end

return M
