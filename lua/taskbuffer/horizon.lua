-- horizon.lua — port of go/horizon.go.
--
-- Resolves a list of user-facing horizon specs into ResolvedHorizons with
-- comparable cutoff dates. All date math goes through strftime.lua's canonical
-- LOCAL-NOON epoch representation (overview §3.1), so cutoffs are directly
-- comparable with </== against Task.due_date and DST-safe.
--
-- Calendar-keyword cutoffs are start-of-next-period (exclusive upper bound).
-- Weekday numbering follows Go's time.Weekday: Sunday=0 .. Saturday=6.

local strftime = require("taskbuffer.strftime")

local M = {}

---@class ResolvedHorizon
---@field label   string
---@field cutoff  integer|nil   -- local-noon epoch; nil for undated horizons
---@field undated boolean
---@field order   integer       -- metadata only; list order drives display

-- Go time.Weekday numbering (Sunday=0 .. Saturday=6).
M.SUNDAY = 0
M.MONDAY = 1
M.TUESDAY = 2
M.WEDNESDAY = 3
M.THURSDAY = 4
M.FRIDAY = 5
M.SATURDAY = 6

local WEEKDAY_NAMES = {
    sunday = M.SUNDAY,
    monday = M.MONDAY,
    tuesday = M.TUESDAY,
    wednesday = M.WEDNESDAY,
    thursday = M.THURSDAY,
    friday = M.FRIDAY,
    saturday = M.SATURDAY,
}

--- Built-in horizon configuration (mirrors defaultHorizonSpecs, horizon.go:31).
---@return table[]
function M.default_horizon_specs()
    return {
        { label = "# Overdue", after = "past" },
        { label = "# Today", after = 0 },
        { label = "# Tomorrow", after = 1 },
        { label = "# This Week", after = 2 },
        { label = "# This Month", after = 8 },
        { label = "# This Year", after = "31d" },
        { label = "# Far Off", after = "366d" },
        { label = "# Someday", undated = true },
    }
end

--- Parse a duration string ("2d","1w","1m","1y") into a day count.
--- Units: d=1, w=7, m=30, y=365. Returns nil + error on malformed input
--- (rejects "1dd", "d2", "2x", "2 d", " 1d", "1d ", "1D", "").
---@param s string
---@return integer|nil days, string|nil err
function M.parse_duration(s)
    if type(s) ~= "string" then
        return nil, "invalid duration string"
    end
    local n_str, unit = s:match("^(%-?%d+)([dwmy])$")
    if not n_str then
        return nil, ('invalid duration string: "%s"'):format(s)
    end
    local n = tonumber(n_str)
    local mult = ({ d = 1, w = 7, m = 30, y = 365 })[unit]
    return n * mult, nil
end

--- Parse a weekday name to Go time.Weekday numbering. Defaults to Monday.
---@param s string
---@return integer  -- 0..6 (Sunday=0)
function M.parse_weekday(s)
    if type(s) ~= "string" then
        return M.MONDAY
    end
    local key = s:match("^%s*(.-)%s*$"):lower()
    local wd = WEEKDAY_NAMES[key]
    if wd == nil then
        return M.MONDAY
    end
    return wd
end

--- Resolve a calendar keyword to a cutoff epoch (start-of-next-period).
---@param kw string
---@param today integer    -- local-noon epoch for the reference day
---@param week_start integer  -- Go weekday numbering (Sunday=0)
---@return integer|nil cutoff, string|nil err
function M.resolve_calendar_keyword(kw, today, week_start)
    local parts = os.date("*t", today)
    if kw == "past" then
        -- AddDate(-100, 0, 0): same month/day, 100 years earlier.
        return strftime.date_to_epoch(parts.year - 100, parts.month, parts.day)
    elseif kw == "yesterday" then
        return strftime.add_days(today, -1)
    elseif kw == "end_of_week" then
        -- Day after the last day of the current week. Go weekday numbering.
        local week_end = week_start - 1 -- Mon(1) -> Sun(0); Sun(0) -> -1
        if week_end < 0 then
            week_end = M.SATURDAY
        end
        local today_wday = parts.wday - 1 -- Lua Sun=1..Sat=7 -> Go Sun=0..Sat=6
        local days_until_end = (week_end - today_wday + 7) % 7
        if days_until_end == 0 then
            days_until_end = 7
        end
        return strftime.add_days(today, days_until_end + 1)
    elseif kw == "end_of_month" then
        -- First day of next month (os.time normalizes month=13 -> next Jan).
        return strftime.date_to_epoch(parts.year, parts.month + 1, 1)
    elseif kw == "end_of_quarter" then
        local q_month = math.floor((parts.month - 1) / 3) * 3 + 4 -- first month of next quarter
        return strftime.date_to_epoch(parts.year, q_month, 1)
    elseif kw == "end_of_year" then
        return strftime.date_to_epoch(parts.year + 1, 1, 1)
    end
    return nil, ('unknown calendar keyword: "%s"'):format(kw)
end

--- Resolve the polymorphic "after" field to a cutoff epoch.
--- Accepts number (day offset, truncated toward zero), string (duration or
--- calendar keyword), or nil.
---@param val number|string|nil
---@param now integer        -- local-noon epoch for "now"
---@param week_start integer -- Go weekday numbering
---@return integer|nil cutoff, string|nil err
function M.parse_after_value(val, now, week_start)
    if type(week_start) == "string" then
        week_start = M.parse_weekday(week_start)
    end
    local today = strftime.start_of_day_noon(now)
    local t = type(val)
    if t == "number" then
        local days = math.modf(val) -- truncate toward zero like Go int()
        return strftime.add_days(today, days)
    elseif t == "string" then
        local days, derr = M.parse_duration(val)
        if not derr then
            return strftime.add_days(today, days)
        end
        return M.resolve_calendar_keyword(val, today, week_start)
    elseif val == nil then
        return nil, "after value is nil"
    end
    return nil, ("unsupported after type: %s"):format(t)
end

--- Resolve a list of horizon specs into ResolvedHorizons (dated first, then
--- undated). nil/empty specs use the defaults. Invalid dated specs are skipped
--- with a warning; if every dated spec fails, falls back to defaults entirely.
---@param specs table[]|nil   -- {label, after, undated, order}
---@param now integer         -- local-noon epoch for "now"
---@param week_start integer|string  -- Go weekday numbering, or a name
---@param overlap string|nil  -- "sorted"|"first_match"|"narrowest"|"explicit"|...
---@return ResolvedHorizon[]
function M.resolve(specs, now, week_start, overlap)
    if type(week_start) == "string" then
        week_start = M.parse_weekday(week_start)
    elseif week_start == nil then
        week_start = M.MONDAY
    end

    if specs == nil or #specs == 0 then
        specs = M.default_horizon_specs()
    end

    local dated = {}
    local undated = {}
    local parse_errors = {}

    for i, s in ipairs(specs) do
        if s.undated then
            local order = #specs + (i - 1) -- Go: len(specs) + i (0-based i)
            if s.order ~= nil then
                order = s.order
            end
            undated[#undated + 1] = {
                label = s.label,
                cutoff = nil,
                undated = true,
                order = order,
            }
        else
            local cutoff, err = M.parse_after_value(s.after, now, week_start)
            if err then
                parse_errors[#parse_errors + 1] = ('horizon "%s": %s'):format(tostring(s.label), err)
            else
                local order = i - 1 -- Go: i (0-based)
                if s.order ~= nil then
                    order = s.order
                end
                dated[#dated + 1] = {
                    label = s.label,
                    cutoff = cutoff,
                    undated = false,
                    order = order,
                }
            end
        end
    end

    if #parse_errors > 0 then
        if vim ~= nil and vim.notify ~= nil then
            for _, e in ipairs(parse_errors) do
                vim.notify("taskbuffer: warning: " .. e, vim.log.levels.WARN)
            end
        end
        if #dated == 0 then
            return M.resolve(M.default_horizon_specs(), now, week_start, overlap)
        end
    end

    if overlap == nil or overlap == "" or overlap == "sorted" then
        table.sort(dated, function(a, b)
            return a.cutoff < b.cutoff
        end)
        for i, h in ipairs(dated) do
            h.order = i - 1
        end
    end

    local result = {}
    for _, h in ipairs(dated) do
        result[#result + 1] = h
    end
    for _, h in ipairs(undated) do
        result[#result + 1] = h
    end
    return result
end

-- Blueprint-compatible alias.
M.resolve_horizons = M.resolve

return M
