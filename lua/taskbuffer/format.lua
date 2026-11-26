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
local async = require("taskbuffer.async")

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

local function append_metadata(parts, task, opts)
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

    append_metadata(parts, task, opts)

    return table.concat(parts)
end

local function pad(text, width, right)
    local spaces = string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
    return right and spaces .. text or text .. spaces
end

local function render_task_text(task, opts)
    local date = task.due_date and strftime.format_epoch(task.due_date, opts.date_strftime or "%Y-%m-%d") or ""
    local parts = {
        pad(date, 10),
        " | ",
        pad(task.due_time or "", 5),
        " |",
        pad(task.duration or "", 4, true),
        " | ",
        task.body,
    }
    append_metadata(parts, task, opts)
    return table.concat(parts)
end

-- Rendered row text is cached on the task object. Only reparsed files produce
-- new task objects, so an action re-renders one row. The entry is valid for the
-- display options that shape the text and the fields it was built from.
local function row_cache_key(opts)
    return table.concat({
        opts.date_strftime or "",
        opts.markers and "m" or "-",
        opts.tag_prefix or "",
        opts.marker_prefix or "",
    }, "\0")
end

-- The interactive view contains only visible text. Source locations stay in
-- the row table; no concealed prefixes, tabs, or date wrappers are needed.
function M.format_task_text(task, opts)
    opts = opts or {}
    local key = opts._row_key or row_cache_key(opts)
    local cache = task._row_cache
    if
        cache
        and cache.key == key
        and cache.body == task.body
        and cache.due_date == task.due_date
        and cache.due_time == task.due_time
        and cache.duration == task.duration
        and cache.tags == task.tags
        and cache.markers == task.markers
    then
        return cache.text
    end
    local text = render_task_text(task, opts)
    task._row_cache = {
        key = key,
        body = task.body,
        due_date = task.due_date,
        due_time = task.due_time,
        duration = task.duration,
        tags = task.tags,
        markers = task.markers,
        text = text,
    }
    return text
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

-- Order of the previous render per section. After an action only a few task
-- objects are new, so sort those and merge them into the surviving order
-- instead of sorting every task again. The merged order is verified, and any
-- doubt falls back to a full sort, so the result always equals a full sort.
local previous_order = {}
local MEMO_MIN = 64

local function in_order(items, less)
    for i = 2, #items do
        if less(items[i], items[i - 1]) then
            return false
        end
    end
    return true
end

local function merge_into_previous(slot, items, less)
    local previous = previous_order[slot]
    if not previous or #items < MEMO_MIN then
        return false
    end
    local current = {}
    for _, task in ipairs(items) do
        current[task] = true
    end
    local survivors, known = {}, {}
    for _, task in ipairs(previous) do
        async.checkpoint()
        if current[task] and not known[task] then
            survivors[#survivors + 1] = task
            known[task] = true
        end
    end
    local fresh = {}
    for _, task in ipairs(items) do
        if not known[task] then
            fresh[#fresh + 1] = task
        end
    end
    if #fresh * 4 > #items then
        return false
    end
    async.sort(fresh, less)
    local merged, left, right = {}, 1, 1
    while left <= #survivors or right <= #fresh do
        async.checkpoint()
        local take_fresh = left > #survivors or (right <= #fresh and less(fresh[right], survivors[left]))
        if take_fresh then
            merged[#merged + 1] = fresh[right]
            right = right + 1
        else
            merged[#merged + 1] = survivors[left]
            left = left + 1
        end
    end
    if #merged ~= #items or not in_order(merged, less) then
        return false
    end
    for i = 1, #merged do
        items[i] = merged[i]
    end
    return true
end

local function sort_section(slot, items, less)
    if not merge_into_previous(slot, items, less) then
        async.sort(items, less)
    end
    previous_order[slot] = items
end

---@class TaskbufferView
---@field lines string[] visible buffer lines
---@field rows table<integer, Task> 1-based row associations (no entries for headings)

--- Group and sort tasks once for either the native view or script export.
---@param tasks table[]|nil
---@param now integer        -- local-noon epoch for "now" (default horizon resolution)
---@param opts FormatOpts|nil
---@param render_line fun(task: Task, opts: FormatOpts): string
---@return TaskbufferView
local function render_rows(tasks, now, opts, render_line)
    tasks = tasks or {}
    opts = opts or {}

    -- Tag filter (OR logic).
    if opts.tag_filter ~= nil and #opts.tag_filter > 0 then
        local filtered = {}
        for _, t in ipairs(tasks) do
            async.checkpoint()
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
        async.checkpoint()
        if t.due_date ~= nil then
            dated[#dated + 1] = t
        else
            undated[#undated + 1] = t
        end
    end

    -- Sort dated: date, then file path, then sort_last after regular, then line.
    sort_section("dated", dated, function(a, b)
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
    sort_section("undated", undated, function(a, b)
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

    local lines, rows = {}, {}
    local count = 0 -- #lines, tracked by hand: the length operator is O(log n)
    local interval = 1
    local last_interval = nil

    for _, t in ipairs(dated) do
        async.checkpoint()
        local date = t.due_date

        if overlap == "first_match" then
            interval = M.first_match_horizon(date, dated_horizons)
        elseif overlap == "narrowest" then
            interval = M.narrowest_horizon(date, dated_horizons)
        else -- "sorted": stateful monotonic forward scan
            -- Most tasks stay in the bucket of the previous one: test it inline.
            local current = dated_horizons[interval]
            local following = dated_horizons[interval + 1]
            if not (date >= current.cutoff and (not following or date < following.cutoff)) then
                for i = interval, #dated_horizons do
                    if M.in_horizon(date, i, dated_horizons) then
                        interval = i
                        break
                    end
                end
            end
        end

        if interval ~= last_interval then
            if last_interval ~= nil then
                count = count + 1
                lines[count] = "" -- blank line between buckets
            end
            count = count + 1
            lines[count] = dated_horizons[interval].label
            last_interval = interval
        end

        count = count + 1
        lines[count] = render_line(t, opts)
        rows[count] = t
    end

    -- Undated section.
    local undated_label = "# Someday"
    if undated_horizon ~= nil then
        undated_label = undated_horizon.label
    end

    if #undated > 0 and not opts.ignore_undated then
        if count > 0 then
            count = count + 1
            lines[count] = ""
        end
        count = count + 1
        lines[count] = undated_label
        for _, t in ipairs(undated) do
            async.checkpoint()
            count = count + 1
            lines[count] = render_line(t, opts)
            rows[count] = t
        end
    end

    return { lines = lines, rows = rows }
end

-- Preserve the serialized format for existing scripts and exports.
function M.format_taskfile(tasks, now, opts)
    local view = render_rows(tasks, now, opts, M.format_task_line)
    return #view.lines > 0 and table.concat(view.lines, "\n") .. "\n" or ""
end

function M.format_view(tasks, now, opts)
    opts = opts or {}
    -- Compute the cache key once per render instead of once per task.
    local keyed = setmetatable({ _row_key = row_cache_key(opts) }, { __index = opts })
    return render_rows(tasks, now, opts, function(task)
        return M.format_task_text(task, keyed)
    end)
end

return M
