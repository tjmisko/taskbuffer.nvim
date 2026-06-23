-- format.lua — port of go/format.go.
--
-- Buckets dated tasks into resolved horizons, total-order sorts, and emits
-- BYTE-EXACT taskfile text (the on-disk round-trip contract, CONTEXT §3). The
-- column layout is fidelity-critical: the leading-tab-only-when-no-time quirk
-- and the right-justified width-4 duration column are pinned by the want
-- strings in go/format_test.go.
--
-- Consumes the canonical Task table (snake_case):
--   { file_path, line_number, body, due_date (local-noon epoch|nil),
--     due_time ("" default), duration ("" default), tags (string[]),
--     markers ({kind,date,time}[]), sort_last (bool) }
-- due_date is compared directly (integer </==) against horizon cutoffs.

local horizon = require("taskbuffer.horizon")
local strftime = require("taskbuffer.strftime")

local M = {}

---@class FormatOpts
---@field markers boolean|nil        -- show marker column (default false)
---@field ignore_undated boolean|nil -- drop the undated section + tasks
---@field tag_filter string[]|nil    -- OR logic; empty/nil = no filter
---@field tag_prefix string|nil      -- default "#"
---@field marker_prefix string|nil   -- default "::"
---@field horizons ResolvedHorizon[]|nil -- nil/empty -> resolve defaults
---@field overlap string|nil         -- "sorted"|"first_match"|"narrowest"; default "sorted"
---@field date_strftime string|nil   -- date-column strftime; default "%Y-%m-%d"

--- Is `date` inside horizon `idx` (1-based)? The last horizon is open-ended.
---@param date integer
---@param idx integer
---@param horizons ResolvedHorizon[]
---@return boolean
function M.in_horizon(date, idx, horizons)
    if idx == #horizons then
        return date >= horizons[idx].cutoff
    end
    return date >= horizons[idx].cutoff and date < horizons[idx + 1].cutoff
end

--- First horizon (in list order) whose cutoff `date` reaches; else last dated;
--- else 1. Returns a 1-based index.
---@param date integer
---@param horizons ResolvedHorizon[]
---@return integer
function M.first_match_horizon(date, horizons)
    for i, h in ipairs(horizons) do
        if not h.undated and date >= h.cutoff then
            return i
        end
    end
    for i = #horizons, 1, -1 do
        if not horizons[i].undated then
            return i
        end
    end
    return 1
end

--- Horizon with the tightest range containing `date`; ties resolve to the
--- earliest matching index. Returns a 1-based index.
---@param date integer
---@param horizons ResolvedHorizon[]
---@return integer
function M.narrowest_horizon(date, horizons)
    local best_idx = nil
    local best_span = math.huge
    -- Open-ended span sentinel: strictly less than `math.huge` (so an
    -- open-ended bucket is selectable) yet strictly greater than any real
    -- epoch-second span (< ~2^35). Do NOT collapse this to math.huge.
    local OPEN = 2 ^ 53

    for i, h in ipairs(horizons) do
        if not h.undated then
            local in_range = false
            local span = nil
            if i == #horizons or horizons[i + 1].undated then
                if date >= h.cutoff then
                    in_range = true
                    span = OPEN
                end
            else
                if date >= h.cutoff and date < horizons[i + 1].cutoff then
                    in_range = true
                    span = horizons[i + 1].cutoff - h.cutoff
                end
            end
            if in_range and span < best_span then
                best_span = span
                best_idx = i
            end
        end
    end

    if best_idx == nil then
        for i = #horizons, 1, -1 do
            if not horizons[i].undated then
                return i
            end
        end
        return 1
    end
    return best_idx
end

--- Right-justify `s` to width `w` (left-pad with spaces); never truncates.
---@param s string
---@param w integer
---@return string
local function lpad(s, w)
    return string.rep(" ", math.max(0, w - #s)) .. s
end

--- Format one task into its byte-exact taskfile line (no trailing newline).
---@param task table
---@param opts FormatOpts
---@return string
function M.format_task_line(task, opts)
    local parts = {}

    -- 1. Location: "<file_path>:<line_number>:1:"
    parts[#parts + 1] = string.format("%s:%d:1:", task.file_path, task.line_number)

    -- 2. Date column.
    if task.due_date ~= nil then
        local date_fmt = opts.date_strftime
        if date_fmt == nil or date_fmt == "" then
            date_fmt = "%Y-%m-%d"
        end
        parts[#parts + 1] = "\t[["
        parts[#parts + 1] = strftime.format_epoch(task.due_date, date_fmt)
        parts[#parts + 1] = "]]"
    else
        parts[#parts + 1] = "\t          " -- TAB + 10 spaces
    end

    -- 3. Time column (7 chars between pipes). Leading TAB ONLY when untimed.
    if task.due_time ~= nil and task.due_time ~= "" then
        parts[#parts + 1] = " | "
        parts[#parts + 1] = task.due_time
        parts[#parts + 1] = " |"
    else
        parts[#parts + 1] = "\t |       |"
    end

    -- 4. Duration column (right-justified to width 4).
    if task.duration ~= nil and task.duration ~= "" then
        parts[#parts + 1] = lpad(task.duration, 4)
        parts[#parts + 1] = " |"
    else
        parts[#parts + 1] = "     |" -- 5 spaces + pipe
    end

    -- 5. Body.
    parts[#parts + 1] = string.format("\t %s \t", task.body)

    -- 6. Tags.
    if task.tags ~= nil and #task.tags > 0 then
        local prefix = opts.tag_prefix
        if prefix == nil or prefix == "" then
            prefix = "#"
        end
        parts[#parts + 1] = " "
        for i, tag in ipairs(task.tags) do
            if i > 1 then
                parts[#parts + 1] = " "
            end
            parts[#parts + 1] = prefix
            parts[#parts + 1] = tag
        end
    end

    -- 7. Markers (only when requested).
    if opts.markers and task.markers ~= nil and #task.markers > 0 then
        local mprefix = opts.marker_prefix
        if mprefix == nil or mprefix == "" then
            mprefix = "::"
        end
        for _, m in ipairs(task.markers) do
            parts[#parts + 1] = " "
            parts[#parts + 1] = mprefix
            parts[#parts + 1] = m.kind
            parts[#parts + 1] = " [["
            parts[#parts + 1] = m.date
            parts[#parts + 1] = "]]"
            if m.time ~= nil and m.time ~= "" then
                parts[#parts + 1] = " "
                parts[#parts + 1] = m.time
            end
        end
    end

    return table.concat(parts)
end

--- OR-membership: does `task` carry any of `tags`?
---@param task table
---@param tags string[]
---@return boolean
function M.task_matches_tags(task, tags)
    for _, filter in ipairs(tags) do
        for _, tag in ipairs(task.tags or {}) do
            if tag == filter then
                return true
            end
        end
    end
    return false
end

--- Format the full taskfile string from a list of canonical Task tables.
---@param tasks table[]|nil
---@param now integer        -- local-noon epoch for "now" (default horizon resolution)
---@param opts FormatOpts|nil
---@return string
function M.format_taskfile(tasks, now, opts)
    tasks = tasks or {}
    opts = opts or {}

    -- Tag filter (OR logic).
    if opts.tag_filter ~= nil and #opts.tag_filter > 0 then
        local filtered = {}
        for _, t in ipairs(tasks) do
            if M.task_matches_tags(t, opts.tag_filter) then
                filtered[#filtered + 1] = t
            end
        end
        tasks = filtered
    end

    -- Resolve horizons if not provided. Go hardcodes time.Monday here; in
    -- production list.lua passes opts.horizons built from config.week_start.
    local horizons = opts.horizons
    if horizons == nil or #horizons == 0 then
        horizons = horizon.resolve(nil, now, horizon.MONDAY, "sorted")
    end

    -- Split horizons: dated in list order; undated -> last one wins.
    local dated_horizons = {}
    local undated_horizon = nil
    for _, h in ipairs(horizons) do
        if h.undated then
            undated_horizon = h
        else
            dated_horizons[#dated_horizons + 1] = h
        end
    end

    -- Split tasks by datedness.
    local dated = {}
    local undated = {}
    for _, t in ipairs(tasks) do
        if t.due_date ~= nil then
            dated[#dated + 1] = t
        else
            undated[#undated + 1] = t
        end
    end

    -- Sort dated: date, then file path, then sort_last after regular, then line.
    table.sort(dated, function(a, b)
        if a.due_date ~= b.due_date then
            return a.due_date < b.due_date
        end
        if a.file_path ~= b.file_path then
            return a.file_path < b.file_path
        end
        local a_last = a.sort_last or false
        local b_last = b.sort_last or false
        if a_last ~= b_last then
            return not a_last
        end
        return a.line_number < b.line_number
    end)

    -- Sort undated: file path, then sort_last, then line.
    table.sort(undated, function(a, b)
        if a.file_path ~= b.file_path then
            return a.file_path < b.file_path
        end
        local a_last = a.sort_last or false
        local b_last = b.sort_last or false
        if a_last ~= b_last then
            return not a_last
        end
        return a.line_number < b.line_number
    end)

    local overlap = opts.overlap
    if overlap == nil or overlap == "" then
        overlap = "sorted"
    end

    local out = {}
    local interval = 1
    local last_interval = nil

    for _, t in ipairs(dated) do
        local date = t.due_date

        if overlap == "first_match" then
            interval = M.first_match_horizon(date, dated_horizons)
        elseif overlap == "narrowest" then
            interval = M.narrowest_horizon(date, dated_horizons)
        else -- "sorted": stateful monotonic forward scan
            for i = interval, #dated_horizons do
                if M.in_horizon(date, i, dated_horizons) then
                    interval = i
                    break
                end
            end
        end

        if interval ~= last_interval then
            if last_interval ~= nil then
                out[#out + 1] = "\n" -- blank line between buckets
            end
            out[#out + 1] = dated_horizons[interval].label
            out[#out + 1] = "\n"
            last_interval = interval
        end

        out[#out + 1] = M.format_task_line(t, opts)
        out[#out + 1] = "\n"
    end

    -- Undated section.
    local undated_label = "# Someday"
    if undated_horizon ~= nil then
        undated_label = undated_horizon.label
    end

    if #undated > 0 and not opts.ignore_undated then
        if #out > 0 then
            out[#out + 1] = "\n"
        end
        out[#out + 1] = undated_label
        out[#out + 1] = "\n"
        for _, t in ipairs(undated) do
            out[#out + 1] = M.format_task_line(t, opts)
            out[#out + 1] = "\n"
        end
    end

    return table.concat(out, "")
end

return M
