-- strftime.lua — the date-format layer (port of go/timeformat.go).
--
-- Replaces timeformat.go AND unifies util.lua's inline strftime converter.
-- There is no Go layout string in Lua: display goes through os.date(fmt, epoch)
-- (Lua's os.date/os.time already speak strftime), and parsing goes through
-- explicit component extraction + validate_date (since os.time silently
-- normalizes 2026-13-45).
--
-- CANONICAL Task.due_date representation (overview §3.1): a LOCAL-NOON epoch
-- integer (nil = undated). Noon dodges every DST transition, is directly
-- comparable with </== for sort+bucketing, and re-displays via os.date. All
-- modules MUST build due dates through date_to_epoch / from a {y,m,d} that this
-- module validated first.

local M = {}

-- Escape a literal string for use inside a Lua pattern.
-- Magic chars in Lua patterns: ^$()%.[]*+-?
local function pesc(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Lua-pattern fragment for each strftime directive that we model. Compound
-- directives (%F, %R) expand to a token sequence so component captures survive.
-- Field letter is what `order` records; "" means a pure literal separator.
local DIRECTIVE = {
    Y = { field = "Y", pat = "%d%d%d%d" },
    m = { field = "m", pat = "%d%d" },
    d = { field = "d", pat = "%d%d" },
    H = { field = "H", pat = "%d%d" },
    M = { field = "M", pat = "%d%d" },
    I = { field = "I", pat = "%d%d?" },
    p = { field = "p", pat = "[AaPp][Mm]" },
}

-- %F -> %Y-%m-%d, %R -> %H:%M, expressed as token lists.
local COMPOUND = {
    F = { "Y", "-", "m", "-", "d" },
    R = { "H", ":", "M" },
}

-- tokenize walks a strftime format like convertStrftime (timeformat.go:61),
-- returning an ordered list of tokens. Each token is either
--   { lit = "<literal char(s)>" }  or  { field = "Y"/"m"/..., pat = "<lua pat>" }
-- Respects %% (escaped percent) so it never expands a literal-percent F/R.
local function tokenize(fmt)
    local tokens = {}
    local function push_directive(letter)
        local d = DIRECTIVE[letter]
        if d then
            tokens[#tokens + 1] = { field = d.field, pat = d.pat }
            return true
        end
        return false
    end

    local i = 1
    local n = #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        if c == "%" and i < n then
            local letter = fmt:sub(i + 1, i + 1)
            if letter == "%" then
                tokens[#tokens + 1] = { lit = "%" }
            elseif COMPOUND[letter] then
                for _, part in ipairs(COMPOUND[letter]) do
                    if DIRECTIVE[part] then
                        push_directive(part)
                    else
                        tokens[#tokens + 1] = { lit = part }
                    end
                end
            elseif not push_directive(letter) then
                -- Unknown directive: pass the two chars through literally.
                tokens[#tokens + 1] = { lit = "%" .. letter }
            end
            i = i + 2
        else
            tokens[#tokens + 1] = { lit = c }
            i = i + 1
        end
    end
    return tokens
end

---@class StrftimeSpec
---@field run      string   -- non-capturing run for embedding, e.g. "%d%d%d%d%-%d%d%-%d%d"
---@field capture  string   -- anchored capture pattern, e.g. "^(%d%d%d%d)%-(%d%d)%-(%d%d)$"
---@field order    string[] -- capture->field map, e.g. {"Y","m","d"}; {} for literals only
---@field has_date boolean  -- true if Y/m/d directives present (validatable)
---@field fmt      string   -- original strftime string (for os.date display)

--- Compile a strftime format into Lua-pattern material. Pure, cacheable.
---@param fmt string
---@return StrftimeSpec
function M.compile(fmt)
    local tokens = tokenize(fmt or "")

    -- Parity transform (timeformat.go:79-87): a single space immediately before
    -- %p collapses into \s* so "1:00 PM", "12:30PM", "1:00  AM" all match.
    for idx, tok in ipairs(tokens) do
        if tok.field == "p" then
            local prev = tokens[idx - 1]
            if prev and prev.lit and prev.lit:sub(-1) == " " then
                prev.lit = prev.lit:sub(1, -2)
                -- Splice a flexible-whitespace token before %p.
                table.insert(tokens, idx, { ws = true })
                break -- only one %p in practice; indices now shifted, stop.
            end
        end
    end

    local run_parts = {}
    local cap_parts = { "^" }
    local order = {}
    local has_date = false

    for _, tok in ipairs(tokens) do
        if tok.ws then
            run_parts[#run_parts + 1] = "%s*"
            cap_parts[#cap_parts + 1] = "%s*"
        elseif tok.field then
            run_parts[#run_parts + 1] = tok.pat
            cap_parts[#cap_parts + 1] = "(" .. tok.pat .. ")"
            order[#order + 1] = tok.field
            if tok.field == "Y" or tok.field == "m" or tok.field == "d" then
                has_date = true
            end
        else
            local frag = pesc(tok.lit)
            run_parts[#run_parts + 1] = frag
            cap_parts[#cap_parts + 1] = frag
        end
    end
    cap_parts[#cap_parts + 1] = "$"

    return {
        run = table.concat(run_parts),
        capture = table.concat(cap_parts),
        order = order,
        has_date = has_date,
        fmt = fmt,
    }
end

--- Extract integer Y/m/d components from a date string using a compiled spec.
---@param date_str string
---@param spec StrftimeSpec
---@return integer? year, integer? month, integer? day  -- nil,nil,nil on no match
function M.components(date_str, spec)
    if not spec.has_date then
        return nil, nil, nil
    end
    local caps = { date_str:match(spec.capture) }
    if #caps == 0 then
        return nil, nil, nil
    end
    local year, month, day
    for i, field in ipairs(spec.order) do
        local v = tonumber(caps[i])
        if field == "Y" then
            year = v
        elseif field == "m" then
            month = v
        elseif field == "d" then
            day = v
        end
    end
    return year, month, day
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function is_leap(year)
    return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
end

--- Strict calendar validator (range + days-in-month + leap year). Mirrors the
--- rejections that Go's time.Parse enforces (date_validation_test.go).
---@param year integer
---@param month integer
---@param day integer
---@return boolean ok, string? reason
function M.validate_date(year, month, day)
    if type(year) ~= "number" or type(month) ~= "number" or type(day) ~= "number" then
        return false, "non-numeric date component"
    end
    if month < 1 or month > 12 then
        return false, "month out of range"
    end
    local max = DAYS_IN_MONTH[month]
    if month == 2 and is_leap(year) then
        max = 29
    end
    if day < 1 or day > max then
        return false, "day out of range"
    end
    return true, nil
end

--- Convert validated Y/m/d into the canonical local-NOON epoch (Task.due_date).
--- Callers MUST validate_date first; this does not re-validate (os.time would
--- silently normalize an out-of-range component).
---@param year integer
---@param month integer
---@param day integer
---@return integer epoch
function M.date_to_epoch(year, month, day)
    return os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
end

--- Display a due-date epoch through the configured strftime format.
---@param epoch integer
---@param fmt string  -- strftime, e.g. "%Y-%m-%d"
---@return string
function M.format_epoch(epoch, fmt)
    return os.date(fmt, epoch)
end

--- Normalize any epoch to local noon of its calendar day. Use this on os.time()
--- "now" before bucketing/comparison so the horizon math is DST-safe.
---@param epoch integer
---@return integer
function M.start_of_day_noon(epoch)
    local t = os.date("*t", epoch)
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 12, min = 0, sec = 0 })
end

--- Add (or subtract) whole calendar days using table-field arithmetic, then
--- re-normalize through os.time. DST-safe — never `epoch + days*86400`
--- (CONTEXT §6.5; replaces the bug at util.lua:214/349).
---@param epoch integer
---@param days integer
---@return integer
function M.add_days(epoch, days)
    local t = os.date("*t", epoch)
    t.day = t.day + days
    t.hour, t.min, t.sec = 12, 0, 0
    return os.time(t)
end

--- Convert a {year,month,day} table to an ISO "YYYY-MM-DD" string. Convenience
--- for util.lua's shift/set string ops (which work on raw buffer text, not the
--- Task.due_date epoch).
---@param d {year:integer,month:integer,day:integer}
---@return string
function M.date_to_iso(d)
    return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

--- Calendar comparison of two {year,month,day} tables.
---@return integer  -- -1 if a<b, 0 if equal, 1 if a>b
function M.date_compare(a, b)
    if a.year ~= b.year then
        return a.year < b.year and -1 or 1
    end
    if a.month ~= b.month then
        return a.month < b.month and -1 or 1
    end
    if a.day ~= b.day then
        return a.day < b.day and -1 or 1
    end
    return 0
end

-- ── DateError helpers (mirror go/main.go:79-100) ──────────────────────────────

---@class DateError
---@field file_path   string
---@field line_number integer|nil  -- nil/0 for frontmatter-level errors
---@field date_str    string
---@field context     string       -- "inline due date", "marker (start)", ...
---@field err          string|nil   -- underlying reason

--- Build a DateError record.
---@return DateError
function M.new_date_error(file_path, line_number, date_str, context, reason)
    return {
        file_path = file_path,
        line_number = line_number,
        date_str = date_str,
        context = context,
        err = reason,
    }
end

--- Append a DateError to the collector if the collector is non-nil (parse.go:96).
---@param list DateError[]|nil
---@param err DateError
function M.collect_date_error(list, err)
    if list ~= nil then
        list[#list + 1] = err
    end
end

--- Format a DateError for stderr-style display (go/main.go:88-93). Wording is an
--- acceptable behavioral diff (06 §10); the file:line and date string are not.
---@param e DateError
---@return string
function M.format_date_error(e)
    if e.line_number and e.line_number > 0 then
        return string.format(
            'date error: %s:%d: invalid %s "%s": %s',
            e.file_path, e.line_number, e.context, e.date_str, e.err or "invalid date"
        )
    end
    return string.format(
        'date error: %s: invalid %s "%s": %s',
        e.file_path, e.context, e.date_str, e.err or "invalid date"
    )
end

return M
