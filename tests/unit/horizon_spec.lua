-- Ported from go/horizon_test.go.
-- Fixed reference day: 2026-02-17 (a Tuesday), matching Go's testToday/testNow.
-- Cutoffs are compared by rendering the resolved epoch through strftime.

local horizon = require("taskbuffer.horizon")
local strftime = require("taskbuffer.strftime")

local MON = horizon.parse_weekday("monday") -- 1
local SUN = horizon.parse_weekday("sunday") -- 0

-- testToday: 2026-02-17 as the canonical local-noon epoch.
local function today_epoch()
    return strftime.date_to_epoch(2026, 2, 17)
end

local function iso(epoch)
    return strftime.format_epoch(epoch, "%Y-%m-%d")
end

describe("horizon.parse_after_value — integer offsets", function()
    local cases = {
        { name = "zero is today", offset = 0, want = "2026-02-17" },
        { name = "one is tomorrow", offset = 1, want = "2026-02-18" },
        { name = "negative is past", offset = -7, want = "2026-02-10" },
    }
    for _, tc in ipairs(cases) do
        it(tc.name, function()
            local cutoff, err = horizon.parse_after_value(tc.offset, today_epoch(), MON)
            assert.is_nil(err)
            assert.are.equal(tc.want, iso(cutoff))
        end)
    end
end)

describe("horizon.parse_after_value — duration strings", function()
    local cases = {
        { dur = "2d", want = "2026-02-19" },
        { dur = "1w", want = "2026-02-24" },
        { dur = "1m", want = "2026-03-19" },
        { dur = "1y", want = "2027-02-17" },
        { dur = "-1w", want = "2026-02-10" },
    }
    for _, tc in ipairs(cases) do
        it(tc.dur, function()
            local cutoff, err = horizon.parse_after_value(tc.dur, today_epoch(), MON)
            assert.is_nil(err)
            assert.are.equal(tc.want, iso(cutoff))
        end)
    end
end)

describe("horizon.parse_after_value — calendar keywords", function()
    -- today is 2026-02-17 (Tuesday), week_start=Monday
    local cases = {
        { kw = "past", want = "1926-02-17" },
        { kw = "yesterday", want = "2026-02-16" },
        { kw = "end_of_week", want = "2026-02-23" },
        { kw = "end_of_month", want = "2026-03-01" },
        { kw = "end_of_quarter", want = "2026-04-01" },
        { kw = "end_of_year", want = "2027-01-01" },
    }
    for _, tc in ipairs(cases) do
        it(tc.kw, function()
            local cutoff, err = horizon.parse_after_value(tc.kw, today_epoch(), MON)
            assert.is_nil(err)
            assert.are.equal(tc.want, iso(cutoff))
        end)
    end

    it("end_of_week with Sunday start lands on the next Sunday", function()
        local cutoff, err = horizon.parse_after_value("end_of_week", today_epoch(), SUN)
        assert.is_nil(err)
        assert.are.equal("2026-02-22", iso(cutoff))
    end)
end)

describe("horizon.parse_after_value — invalid / unsupported input", function()
    it("returns error for a bogus keyword", function()
        local cutoff, err = horizon.parse_after_value("bogus", today_epoch(), MON)
        assert.is_nil(cutoff)
        assert.is_not_nil(err)
    end)

    it("returns error for nil", function()
        local cutoff, err = horizon.parse_after_value(nil, today_epoch(), MON)
        assert.is_nil(cutoff)
        assert.is_not_nil(err)
    end)

    it("rejects boolean with an 'unsupported after type' message", function()
        local cutoff, err = horizon.parse_after_value(true, today_epoch(), MON)
        assert.is_nil(cutoff)
        assert.is_not_nil(err)
        assert.is_not_nil(err:find("unsupported after type", 1, true))
    end)

    it("rejects a table (slice)", function()
        local cutoff, err = horizon.parse_after_value({ "a" }, today_epoch(), MON)
        assert.is_nil(cutoff)
        assert.is_not_nil(err)
    end)

    it("accepts an integer offset of 5", function()
        local cutoff, err = horizon.parse_after_value(5, today_epoch(), MON)
        assert.is_nil(err)
        assert.are.equal("2026-02-22", iso(cutoff))
    end)
end)

describe("horizon.parse_weekday", function()
    it("parses valid weekday names case-insensitively", function()
        assert.are.equal(horizon.MONDAY, horizon.parse_weekday("monday"))
        assert.are.equal(horizon.SUNDAY, horizon.parse_weekday("Sunday"))
        assert.are.equal(horizon.FRIDAY, horizon.parse_weekday("FRIDAY"))
    end)

    it("defaults to Monday for empty / invalid", function()
        assert.are.equal(horizon.MONDAY, horizon.parse_weekday(""))
        assert.are.equal(horizon.MONDAY, horizon.parse_weekday("invalid"))
    end)
end)

describe("horizon.parse_duration", function()
    local cases = {
        { input = "2d", want = 2 },
        { input = "1w", want = 7 },
        { input = "1m", want = 30 },
        { input = "1y", want = 365 },
        { input = "-1w", want = -7 },
        { input = "3d", want = 3 },
        { input = "bogus", err = true },
        { input = "", err = true },
        -- edge cases
        { input = "0d", want = 0 },
        { input = "0w", want = 0 },
        { input = "999y", want = 364635 },
        { input = "2x", err = true },
        { input = "1dd", err = true },
        { input = "d2", err = true },
        { input = "2 d", err = true },
        { input = " 1d", err = true },
        { input = "1d ", err = true },
        { input = "1D", err = true },
    }
    for _, tc in ipairs(cases) do
        it(("%q -> %s"):format(tc.input, tc.err and "error" or tostring(tc.want)), function()
            local days, err = horizon.parse_duration(tc.input)
            if tc.err then
                assert.is_nil(days)
                assert.is_not_nil(err)
            else
                assert.is_nil(err)
                assert.are.equal(tc.want, days)
            end
        end)
    end
end)

describe("horizon.resolve_calendar_keyword — week boundaries", function()
    local cases = {
        -- Monday-start week (Mon-Sun), week of Feb 16-22
        { name = "mon-start Mon Feb16", y = 2026, m = 2, d = 16, ws = MON, want = "2026-02-23" },
        { name = "mon-start Tue Feb17", y = 2026, m = 2, d = 17, ws = MON, want = "2026-02-23" },
        { name = "mon-start Wed Feb18", y = 2026, m = 2, d = 18, ws = MON, want = "2026-02-23" },
        { name = "mon-start Thu Feb19", y = 2026, m = 2, d = 19, ws = MON, want = "2026-02-23" },
        { name = "mon-start Fri Feb20", y = 2026, m = 2, d = 20, ws = MON, want = "2026-02-23" },
        { name = "mon-start Sat Feb21", y = 2026, m = 2, d = 21, ws = MON, want = "2026-02-23" },
        { name = "mon-start Sun Feb22", y = 2026, m = 2, d = 22, ws = MON, want = "2026-03-02" },
        -- Sunday-start week (Sun-Sat), week of Feb 15-21
        { name = "sun-start Sun Feb15", y = 2026, m = 2, d = 15, ws = SUN, want = "2026-02-22" },
        { name = "sun-start Mon Feb16", y = 2026, m = 2, d = 16, ws = SUN, want = "2026-02-22" },
        { name = "sun-start Tue Feb17", y = 2026, m = 2, d = 17, ws = SUN, want = "2026-02-22" },
        { name = "sun-start Wed Feb18", y = 2026, m = 2, d = 18, ws = SUN, want = "2026-02-22" },
        { name = "sun-start Thu Feb19", y = 2026, m = 2, d = 19, ws = SUN, want = "2026-02-22" },
        { name = "sun-start Fri Feb20", y = 2026, m = 2, d = 20, ws = SUN, want = "2026-02-22" },
        { name = "sun-start Sat Feb21", y = 2026, m = 2, d = 21, ws = SUN, want = "2026-03-01" },
    }
    for _, tc in ipairs(cases) do
        it(tc.name, function()
            local cutoff, err =
                horizon.resolve_calendar_keyword("end_of_week", strftime.date_to_epoch(tc.y, tc.m, tc.d), tc.ws)
            assert.is_nil(err)
            assert.are.equal(tc.want, iso(cutoff))
        end)
    end
end)

describe("horizon.resolve_calendar_keyword — month boundaries", function()
    local cases = {
        { name = "Jan 31", y = 2026, m = 1, d = 31, want = "2026-02-01" },
        { name = "Feb 28 non-leap", y = 2026, m = 2, d = 28, want = "2026-03-01" },
        { name = "Feb 29 leap year", y = 2028, m = 2, d = 29, want = "2028-03-01" },
        { name = "Dec 31 year boundary", y = 2026, m = 12, d = 31, want = "2027-01-01" },
        { name = "Feb 1 first day", y = 2026, m = 2, d = 1, want = "2026-03-01" },
    }
    for _, tc in ipairs(cases) do
        it(tc.name, function()
            local cutoff, err =
                horizon.resolve_calendar_keyword("end_of_month", strftime.date_to_epoch(tc.y, tc.m, tc.d), MON)
            assert.is_nil(err)
            assert.are.equal(tc.want, iso(cutoff))
        end)
    end
end)

describe("horizon.resolve_calendar_keyword — quarter boundaries", function()
    local cases = {
        { name = "Q1 mid", y = 2026, m = 1, d = 15, want = "2026-04-01" },
        { name = "Q2 mid", y = 2026, m = 4, d = 15, want = "2026-07-01" },
        { name = "Q3 mid", y = 2026, m = 7, d = 15, want = "2026-10-01" },
        { name = "Q4 mid", y = 2026, m = 10, d = 15, want = "2027-01-01" },
        { name = "Q1 last day", y = 2026, m = 3, d = 31, want = "2026-04-01" },
        { name = "Q2 last day", y = 2026, m = 6, d = 30, want = "2026-07-01" },
        { name = "Q3 last day", y = 2026, m = 9, d = 30, want = "2026-10-01" },
        { name = "Q4 last day", y = 2026, m = 12, d = 31, want = "2027-01-01" },
    }
    for _, tc in ipairs(cases) do
        it(tc.name, function()
            local cutoff, err =
                horizon.resolve_calendar_keyword("end_of_quarter", strftime.date_to_epoch(tc.y, tc.m, tc.d), MON)
            assert.is_nil(err)
            assert.are.equal(tc.want, iso(cutoff))
        end)
    end
end)

describe("horizon.resolve", function()
    it("uses defaults when specs is nil (7 dated + 1 undated)", function()
        local horizons = horizon.resolve(nil, today_epoch(), MON, "sorted")
        assert.are.equal(8, #horizons)
        local last = horizons[#horizons]
        assert.is_true(last.undated)
        assert.are.equal("# Someday", last.label)
        assert.are.equal("# Overdue", horizons[1].label)
    end)

    it("uses defaults for an empty slice", function()
        local horizons = horizon.resolve({}, today_epoch(), MON, "sorted")
        assert.are.equal(8, #horizons)
    end)

    it("preserves custom specs in order", function()
        local specs = {
            { label = "# Past", after = "past" },
            { label = "# Now", after = 0 },
            { label = "# Soon", after = "1w" },
            { label = "# Backlog", undated = true },
        }
        local horizons = horizon.resolve(specs, today_epoch(), MON, "sorted")
        assert.are.equal(4, #horizons)
        assert.are.equal("# Past", horizons[1].label)
        assert.are.equal("# Now", horizons[2].label)
        assert.are.equal("# Soon", horizons[3].label)
        assert.are.equal("# Backlog", horizons[4].label)
        assert.is_true(horizons[4].undated)
    end)

    it("sorts dated horizons by cutoff ascending under 'sorted' overlap", function()
        local specs = {
            { label = "# Later", after = "1w" },
            { label = "# Now", after = 0 },
            { label = "# Past", after = "past" },
        }
        local horizons = horizon.resolve(specs, today_epoch(), MON, "sorted")
        assert.are.equal(3, #horizons)
        assert.are.equal("# Past", horizons[1].label)
        assert.are.equal("# Now", horizons[2].label)
        assert.are.equal("# Later", horizons[3].label)
        for i = 2, #horizons do
            assert.is_true(horizons[i].cutoff > horizons[i - 1].cutoff)
        end
    end)

    it("falls back to defaults when every dated spec is invalid", function()
        local specs = { { label = "# Bad", after = "bogus_keyword" } }
        local horizons = horizon.resolve(specs, today_epoch(), MON, "sorted")
        assert.are.equal(8, #horizons)
    end)

    it("keeps valid specs and skips invalid ones", function()
        local specs = {
            { label = "# Today", after = 0 },
            { label = "# Bad", after = "bogus_keyword" },
            { label = "# Someday", undated = true },
        }
        local horizons = horizon.resolve(specs, today_epoch(), MON, "sorted")
        assert.are.equal(2, #horizons) -- 1 dated + 1 undated
    end)

    it("keeps both horizons with duplicate cutoffs", function()
        local specs = {
            { label = "# Alpha", after = 0 },
            { label = "# Beta", after = 0 },
        }
        local horizons = horizon.resolve(specs, today_epoch(), MON, "sorted")
        assert.are.equal(2, #horizons)
        local labels = {}
        for _, h in ipairs(horizons) do
            labels[h.label] = true
        end
        assert.is_true(labels["# Alpha"])
        assert.is_true(labels["# Beta"])
    end)

    it("preserves explicit order values under non-sorted overlap", function()
        local specs = {
            { label = "# First", after = 0, order = 10 },
            { label = "# Second", after = 1, order = 5 },
            { label = "# Third", after = 2, order = 1 },
        }
        local horizons = horizon.resolve(specs, today_epoch(), MON, "explicit")
        assert.are.equal(3, #horizons)
        local by_label = {}
        for _, h in ipairs(horizons) do
            by_label[h.label] = h.order
        end
        assert.are.equal(10, by_label["# First"])
        assert.are.equal(5, by_label["# Second"])
        assert.are.equal(1, by_label["# Third"])
    end)

    it("keeps only-undated specs", function()
        local specs = {
            { label = "# Backlog", undated = true },
            { label = "# Ideas", undated = true },
        }
        local horizons = horizon.resolve(specs, today_epoch(), MON, "sorted")
        assert.are.equal(2, #horizons)
        for _, h in ipairs(horizons) do
            assert.is_true(h.undated)
        end
    end)

    it("keeps multiple undated horizons", function()
        local specs = {
            { label = "# Today", after = 0 },
            { label = "# Backlog", undated = true },
            { label = "# Ideas", undated = true },
        }
        local horizons = horizon.resolve(specs, today_epoch(), MON, "sorted")
        assert.are.equal(3, #horizons)
        local undated_count = 0
        for _, h in ipairs(horizons) do
            if h.undated then
                undated_count = undated_count + 1
            end
        end
        assert.are.equal(2, undated_count)
    end)

    it("accepts a week_start name string defensively", function()
        local horizons = horizon.resolve(nil, today_epoch(), "monday", "sorted")
        assert.are.equal(8, #horizons)
    end)
end)

describe("horizon DST regression (non-golden)", function()
    -- add_days must never drift a calendar day across a spring-forward
    -- transition. America/Santiago historically had midnight DST jumps.
    it("add_days stays calendar-correct under a midnight-DST zone", function()
        -- getenv returns v:null when unset; setenv(v:null) restores "unset".
        local saved = vim.fn.getenv("TZ")
        vim.fn.setenv("TZ", "America/Santiago")
        local epoch = strftime.date_to_epoch(2019, 9, 7) -- day before a historic transition
        local plus1 = strftime.add_days(epoch, 1)
        assert.are.equal("2019-09-08", strftime.format_epoch(plus1, "%Y-%m-%d"))
        local plus0 = strftime.add_days(epoch, 0)
        assert.are.equal("2019-09-07", strftime.format_epoch(plus0, "%Y-%m-%d"))
        vim.fn.setenv("TZ", saved)
    end)
end)
