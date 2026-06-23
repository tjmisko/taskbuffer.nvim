-- parse.lua — the task-line parser (port of go/parse.go).
--
-- Strategy (overview §3.2, blueprint 02-parse §3a): pure-Lua hybrid. Lua
-- patterns have no alternation / optional non-capturing groups / `\d{n}`, so:
--   * checkbox detection is LITERAL prefix matching over a longest-first list
--     (reproduces Go's regex-alternation longest-match without escaping);
--   * the inline-due date and markers use Lua patterns whose date/time fragments
--     come from strftime.compile() (the single strftime->pattern source), with
--     the optional time handled by trying a with-time then a no-time variant.
--
-- CANONICAL Task.due_date is a LOCAL-NOON epoch integer (overview §3.1), built
-- only via strftime.date_to_epoch(y,m,d) AFTER strftime.validate_date passes.
-- nil = undated. Markers keep RAW unnormalized date/time strings (never epochs).

local strftime = require("taskbuffer.strftime")

local M = {}

---@class Task
---@field file_path   string
---@field line_number integer
---@field body        string
---@field due_date    integer|nil  -- local-noon epoch; nil = undated
---@field due_time    string       -- "" or verbatim time string ("16:00", "1:00 PM")
---@field duration    string       -- "" or "30m"
---@field tags        string[]     -- prefix-stripped, source order
---@field status      string       -- "open"|"done"|"irrelevant"|<custom>
---@field markers     {kind:string,date:string,time:string}[]  -- date/time RAW
---@field sort_last   boolean

---@class RawMatch
---@field path        string
---@field line_number integer
---@field text        string

-- Default config fragments (mirror parse.go:58-63 / :122 / :148).
local DEFAULT_CHECKBOX = { open = "- [ ]", done = "- [x]", irrelevant = "- [-]" }
local DEFAULT_DATE_FMT = "%Y-%m-%d"
local DEFAULT_TIME_FMT = "%H:%M"
local DEFAULT_TAG_PREFIX = "#"
local DEFAULT_MARKER_PREFIX = "::"
local DEFAULT_WRAPPER = { "(@[[", "]]", ")" }

-- Split `s` on every literal occurrence of `delim` (plain, not pattern).
-- Mirrors strings.Split: N delimiters -> N+1 parts, including empty ends.
local function split_plain(s, delim)
    local parts = {}
    local start = 1
    while true do
        local i = string.find(s, delim, start, true)
        if not i then
            parts[#parts + 1] = s:sub(start)
            return parts
        end
        parts[#parts + 1] = s:sub(start, i - 1)
        start = i + #delim
    end
end

--- Build a ParseContext from a config table (the shape of
--- require("taskbuffer.config").values). Reads config.formats.{date,time,
--- tag_prefix,checkbox,date_wrapper,marker_prefix} and config.strict, falling
--- back to defaults for missing/zero fields (parse.go:50-156).
---@param config table
---@return table ctx
function M.new_parse_context(config)
    config = config or {}
    local formats = config.formats or {}
    local ctx = {}

    -- Duration is hardcoded <Nm> for parity (parse.go:52 ignores configured fmt).
    ctx.duration_pat = "<(%d+)m>"

    -- strict may not exist in config yet; default false (DECISION-S).
    ctx.strict = config.strict == true
    -- Collector slot; callers assign a list to enable error collection (nil = ignore).
    ctx.date_errors = nil

    -- ── Checkbox / status ────────────────────────────────────────────────────
    local checkbox = formats.checkbox
    if type(checkbox) ~= "table" or next(checkbox) == nil then
        checkbox = DEFAULT_CHECKBOX
    end
    -- Reject empty / whitespace-only checkbox strings (parse.go:67-71).
    local filtered = {}
    for name, cb in pairs(checkbox) do
        if type(cb) == "string" and vim.trim(cb) ~= "" then
            filtered[name] = cb
        end
    end
    ctx.checkbox = filtered

    -- status_map: checkbox string -> status name, with deterministic duplicate
    -- resolution — alphabetically-first status name wins (parse.go:78-87).
    ctx.status_map = {}
    for name, cb in pairs(filtered) do
        local existing = ctx.status_map[cb]
        if existing == nil or name < existing then
            ctx.status_map[cb] = name
        end
    end

    -- Unique checkbox strings, sorted LONGEST-FIRST (ties alpha). Tried in this
    -- order as literal prefixes, reproducing Go's sortByLengthDesc + alternation
    -- longest-match (parse.go:99-105).
    local seen = {}
    ctx.checkboxes = {}
    for _, cb in pairs(filtered) do
        if not seen[cb] then
            seen[cb] = true
            ctx.checkboxes[#ctx.checkboxes + 1] = cb
        end
    end
    table.sort(ctx.checkboxes, function(a, b)
        if #a ~= #b then
            return #a > #b
        end
        return a < b
    end)

    -- ── Tag prefix ───────────────────────────────────────────────────────────
    local tag_prefix = formats.tag_prefix
    if type(tag_prefix) ~= "string" or tag_prefix == "" then
        tag_prefix = DEFAULT_TAG_PREFIX
    end
    ctx.tag_prefix = tag_prefix
    -- tagRe parity: prefix + [A-Za-z_][\w-]*  (Lua %w omits _, so rest is [%w_-]).
    ctx.tag_pat = vim.pesc(tag_prefix) .. "([%a_][%w_-]*)"

    -- ── Date / time formats ──────────────────────────────────────────────────
    local date_fmt = formats.date
    if type(date_fmt) ~= "string" or date_fmt == "" then
        date_fmt = DEFAULT_DATE_FMT
    end
    local time_fmt = formats.time
    if type(time_fmt) ~= "string" or time_fmt == "" then
        time_fmt = DEFAULT_TIME_FMT
    end
    ctx.date_spec = strftime.compile(date_fmt)
    ctx.time_spec = strftime.compile(time_fmt)
    local D = ctx.date_spec.run
    local T = ctx.time_spec.run

    -- ── Inline due-date matcher (parse.go:131-143) ───────────────────────────
    -- Two concrete patterns (with-time / no-time) replace Go's optional time
    -- group. The lazy `.-` between the open delimiter and the date reproduces
    -- Go's alias/path strip `(?:[^|\]]*\|)?(?:.*/)?` (DECISION-E1).
    local wrapper = formats.date_wrapper
    local o, c2, c3, two_elem
    if type(wrapper) == "table" and #wrapper == 3 and wrapper[1] ~= "" and wrapper[2] ~= "" and wrapper[3] ~= "" then
        o, c2, c3, two_elem = wrapper[1], wrapper[2], wrapper[3], false
    elseif type(wrapper) == "table" and #wrapper == 2 and wrapper[1] ~= "" and wrapper[2] ~= "" then
        o, c2, two_elem = wrapper[1], wrapper[2], true
    else
        o, c2, c3, two_elem = DEFAULT_WRAPPER[1], DEFAULT_WRAPPER[2], DEFAULT_WRAPPER[3], false
    end
    local po, pc2 = vim.pesc(o), vim.pesc(c2)
    if two_elem then
        -- Time sits before the single closer (parse.go:141).
        ctx.date_pat_time = po .. ".-(" .. D .. ")%s*(" .. T .. ")" .. pc2
        ctx.date_pat_notime = po .. ".-(" .. D .. ")%s*" .. pc2
    else
        -- Time sits between the second and third wrapper elements (parse.go:134).
        local pc3 = vim.pesc(c3)
        ctx.date_pat_time = po .. ".-(" .. D .. ")" .. pc2 .. "%s*(" .. T .. ")" .. pc3
        ctx.date_pat_notime = po .. ".-(" .. D .. ")" .. pc2 .. "%s*" .. pc3
    end

    -- ── Marker prefix + matchers ─────────────────────────────────────────────
    local marker_prefix = formats.marker_prefix
    if type(marker_prefix) ~= "string" or marker_prefix == "" then
        marker_prefix = DEFAULT_MARKER_PREFIX
    end
    ctx.marker_prefix = marker_prefix
    -- Markers always use literal [[ ]] regardless of wrapper (parse.go:151).
    -- `\w` -> `[%w_]` since Lua %w omits underscore.
    ctx.marker_pat_time = "([%w_]+)%s+%[%[.-(" .. D .. ")%]%]%s*(" .. T .. ")"
    ctx.marker_pat_notime = "([%w_]+)%s+%[%[.-(" .. D .. ")%]%]"
    -- Locates where real markers begin (prefix + keyword + [[): avoids treating a
    -- bare prefix in body text as a marker boundary (parse.go:154).
    ctx.marker_start_pat = vim.pesc(marker_prefix) .. "%s*[%w_]+%s+%[%["

    return ctx
end

-- Select the inline date group, mirroring Go's leftmost match over an optional
-- time. Both variants can match (a timed vs a timeless group); the one whose
-- match ENDS earliest is the actual leftmost group, so prefer it. Returns
-- s, e (1-based span), date_str, time_str — or nil when no group matched.
local function find_date_group(line, ctx)
    local st, et, dt, tt = line:find(ctx.date_pat_time)
    local sn, en, dn = line:find(ctx.date_pat_notime)
    if st and sn then
        if et <= en then
            return st, et, dt, tt
        end
        return sn, en, dn, ""
    elseif st then
        return st, et, dt, tt
    elseif sn then
        return sn, en, dn, ""
    end
    return nil
end

--- Parse one matched line into a Task.
---@param match RawMatch
---@param ctx table
---@return Task|nil task, string|nil err
function M.parse_task(match, ctx)
    local line = (match.text:gsub("^[ \t]+", "")) -- TrimLeft " \t"
    line = (line:gsub("[\r\n]+$", "")) -- TrimRight "\n\r"

    -- 1. Status — literal longest-first prefix match (parse.go:187-196).
    local checkbox_str, status
    for _, cb in ipairs(ctx.checkboxes) do
        if line:sub(1, #cb) == cb then
            checkbox_str = cb
            status = ctx.status_map[cb]
            break
        end
    end
    if not checkbox_str then
        return nil, "no checkbox found in line: " .. line
    end
    local checkbox_end = #checkbox_str

    -- 2. Inline due date (optional). The group span is recorded as soon as the
    -- date GROUP matches, regardless of validity — body/markers slice off it.
    local due_date, due_time = nil, ""
    local date_group_start, date_group_end, dstr, tstr = find_date_group(line, ctx)
    if date_group_start then
        local y, mo, d = strftime.components(dstr, ctx.date_spec)
        local ok, reason = strftime.validate_date(y, mo, d)
        if ok then
            due_date = strftime.date_to_epoch(y, mo, d)
            due_time = tstr or ""
        elseif ctx.strict then
            -- Strict: record the error, treat as undated, keep parsing (parse.go:211-219).
            strftime.collect_date_error(
                ctx.date_errors,
                strftime.new_date_error(match.path, match.line_number, dstr, "inline due date", reason)
            )
        else
            -- Non-strict: skip the whole line (parse.go:220-222).
            return nil, string.format('unparseable date "%s": %s', dstr, reason or "invalid date")
        end
    end

    -- 3. Duration (parse.go:230-235). Hardcoded <Nm> over the whole line.
    local dur_num = line:match(ctx.duration_pat)
    local duration = dur_num and (dur_num .. "m") or ""

    -- 4. Markers — slice after the date group (or from the first real marker for
    -- undated lines), split on the marker prefix, parse each segment (parse.go:237-275).
    local markers = {}
    local after
    if date_group_start then
        after = line:sub(date_group_end + 1)
    else
        local mi = line:find(ctx.marker_start_pat)
        after = mi and line:sub(mi) or ""
    end
    for _, raw_seg in ipairs(split_plain(after, ctx.marker_prefix)) do
        local seg = vim.trim(raw_seg)
        if seg ~= "" then
            local kind, mdate, mtime = seg:match(ctx.marker_pat_time)
            if not kind then
                kind, mdate = seg:match(ctx.marker_pat_notime)
                mtime = ""
            end
            if kind then
                if ctx.strict and mdate ~= "" then
                    local y, mo, d = strftime.components(mdate, ctx.date_spec)
                    local ok, reason = strftime.validate_date(y, mo, d)
                    if not ok then
                        strftime.collect_date_error(
                            ctx.date_errors,
                            strftime.new_date_error(
                                match.path,
                                match.line_number,
                                mdate,
                                "marker (" .. kind .. ")",
                                reason
                            )
                        )
                    end
                end
                markers[#markers + 1] = { kind = kind, date = mdate, time = mtime or "" }
            end
        end
    end

    -- 5. Tags — collected over the WHOLE line in source order (parse.go:278).
    local tags = {}
    for t in line:gmatch(ctx.tag_pat) do
        tags[#tags + 1] = t
    end

    -- 6. Body (parse.go:284-303).
    local body
    if date_group_start then
        body = line:sub(checkbox_end + 1, date_group_start - 1)
    else
        local mi = line:find(ctx.marker_start_pat)
        local body_end = mi and (mi - 1) or #line
        body = line:sub(checkbox_end + 1, body_end)
    end
    if dur_num then
        body = (body:gsub(vim.pesc("<" .. dur_num .. "m>"), "", 1))
    end
    body = (body:gsub(ctx.tag_pat, ""))
    body = vim.trim(body)

    return {
        file_path = match.path,
        line_number = match.line_number,
        body = body,
        due_date = due_date,
        due_time = due_time,
        duration = duration,
        tags = tags,
        status = status,
        markers = markers,
        sort_last = false,
    }
end

--- Parse many matches, dropping unparseable lines (parse.go:318-331).
---@param raw_matches RawMatch[]
---@param ctx table
---@return Task[]
function M.parse_tasks(raw_matches, ctx)
    local tasks = {}
    for _, m in ipairs(raw_matches) do
        local task = M.parse_task(m, ctx)
        if task then
            tasks[#tasks + 1] = task
        end
    end
    return tasks
end

return M
