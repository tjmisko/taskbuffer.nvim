-- Ported from go/timeformat_test.go and go/date_validation_test.go.
-- The Go-layout half (StrftimeToGo) is intentionally dropped: Lua has no
-- time.Parse layout. We test the Lua-pattern half + strict validation + the
-- canonical noon-epoch helpers instead.

local strftime = require("taskbuffer.strftime")

describe("strftime.compile + components", function()
    local function matches(fmt, s)
        local spec = strftime.compile(fmt)
        return s:match("^" .. spec.run .. "$") ~= nil
    end

    -- TestStrftimeToRegex_Matches
    it("ISO date pattern matches ISO, not US", function()
        assert.is_true(matches("%Y-%m-%d", "2026-03-04"))
        assert.is_false(matches("%Y-%m-%d", "03/04/2026"))
    end)

    it("US date pattern matches US, not ISO", function()
        assert.is_true(matches("%m/%d/%Y", "03/04/2026"))
        assert.is_false(matches("%m/%d/%Y", "2026-03-04"))
    end)

    it("dot date pattern treats dots as literals", function()
        assert.is_true(matches("%d.%m.%Y", "04.03.2026"))
        assert.is_false(matches("%d.%m.%Y", "04X03X2026"))
    end)

    it("compact date matches", function()
        assert.is_true(matches("%Y%m%d", "20260304"))
    end)

    it("24h time matches, rejects 12h", function()
        assert.is_true(matches("%H:%M", "15:04"))
        assert.is_false(matches("%H:%M", "3:04 PM"))
    end)

    -- TestStrftimeToRegex_12hTimeSpaceHandling
    it("12h time collapses the space before %p into flexible whitespace", function()
        assert.is_true(matches("%I:%M %p", "1:00 PM"))
        assert.is_true(matches("%I:%M %p", "12:30PM")) -- no space
        assert.is_true(matches("%I:%M %p", "1:00  AM")) -- double space
    end)

    it("%F and %R shorthand expand to their components", function()
        assert.is_true(matches("%F", "2026-01-02"))
        assert.is_true(matches("%R", "15:04"))
    end)

    it("components extracts integer Y/m/d for date specs", function()
        local spec = strftime.compile("%Y-%m-%d")
        local y, m, d = strftime.components("2026-02-17", spec)
        assert.are.equal(2026, y)
        assert.are.equal(2, m)
        assert.are.equal(17, d)
    end)

    it("components extracts from custom US format", function()
        local spec = strftime.compile("%m/%d/%Y")
        local y, m, d = strftime.components("03/04/2026", spec)
        assert.are.equal(2026, y)
        assert.are.equal(3, m)
        assert.are.equal(4, d)
    end)

    it("components returns nil for time-only specs", function()
        local spec = strftime.compile("%H:%M")
        assert.is_false(spec.has_date)
        local y = strftime.components("15:04", spec)
        assert.is_nil(y)
    end)
end)

describe("strftime.validate_date", function()
    -- invalidDateCases from date_validation_test.go
    local invalid = {
        { 2026, 0, 15 }, { 2026, 13, 1 }, { 2026, 99, 1 },
        { 2026, 1, 0 }, { 2026, 1, 32 }, { 2026, 1, 99 },
        { 2026, 4, 31 }, { 2026, 6, 31 }, { 2026, 9, 31 }, { 2026, 11, 31 },
        { 2026, 2, 30 }, { 2026, 2, 31 }, { 2025, 2, 29 }, { 2100, 2, 29 },
    }
    local valid = {
        { 2026, 1, 1 }, { 2026, 12, 31 }, { 2025, 2, 28 }, { 2024, 2, 29 },
        { 2000, 2, 29 }, { 2026, 4, 30 }, { 2026, 6, 30 },
    }

    for _, c in ipairs(invalid) do
        it(("rejects %04d-%02d-%02d"):format(c[1], c[2], c[3]), function()
            assert.is_false((strftime.validate_date(c[1], c[2], c[3])))
        end)
    end

    for _, c in ipairs(valid) do
        it(("accepts %04d-%02d-%02d"):format(c[1], c[2], c[3]), function()
            assert.is_true((strftime.validate_date(c[1], c[2], c[3])))
        end)
    end
end)

describe("strftime noon-epoch helpers", function()
    it("date_to_epoch round-trips through format_epoch", function()
        local e = strftime.date_to_epoch(2026, 2, 17)
        assert.are.equal("2026-02-17", strftime.format_epoch(e, "%Y-%m-%d"))
    end)

    it("date_to_epoch lands on local noon (DST-safe)", function()
        local e = strftime.date_to_epoch(2026, 2, 17)
        local t = os.date("*t", e)
        assert.are.equal(12, t.hour)
        assert.are.equal(2026, t.year)
        assert.are.equal(2, t.month)
        assert.are.equal(17, t.day)
    end)

    it("add_days crosses month boundaries", function()
        local e = strftime.date_to_epoch(2026, 1, 31)
        assert.are.equal("2026-02-01", strftime.format_epoch(strftime.add_days(e, 1), "%Y-%m-%d"))
        assert.are.equal("2026-01-30", strftime.format_epoch(strftime.add_days(e, -1), "%Y-%m-%d"))
    end)

    it("add_days survives a US spring-forward DST boundary", function()
        -- 2026-03-08 is US DST spring-forward; noon-anchored math must not slip a day.
        local e = strftime.date_to_epoch(2026, 3, 7)
        assert.are.equal("2026-03-08", strftime.format_epoch(strftime.add_days(e, 1), "%Y-%m-%d"))
        assert.are.equal("2026-03-09", strftime.format_epoch(strftime.add_days(e, 2), "%Y-%m-%d"))
    end)

    it("start_of_day_noon normalizes an arbitrary epoch to noon of that day", function()
        local morning = os.time({ year = 2026, month = 6, day = 23, hour = 3, min = 14, sec = 9 })
        local noon = strftime.start_of_day_noon(morning)
        assert.are.equal("2026-06-23", strftime.format_epoch(noon, "%Y-%m-%d"))
        assert.are.equal(12, os.date("*t", noon).hour)
    end)

    it("date_to_iso and date_compare operate on {y,m,d} tables", function()
        assert.are.equal("2026-02-09", strftime.date_to_iso({ year = 2026, month = 2, day = 9 }))
        assert.are.equal(-1, strftime.date_compare({ year = 2026, month = 1, day = 1 }, { year = 2026, month = 1, day = 2 }))
        assert.are.equal(0, strftime.date_compare({ year = 2026, month = 1, day = 1 }, { year = 2026, month = 1, day = 1 }))
        assert.are.equal(1, strftime.date_compare({ year = 2027, month = 1, day = 1 }, { year = 2026, month = 12, day = 31 }))
    end)
end)

describe("strftime DateError helpers", function()
    it("collect_date_error appends only when collector is non-nil", function()
        local list = {}
        strftime.collect_date_error(list, strftime.new_date_error("f.md", 5, "2026-13-01", "inline due date", "bad"))
        assert.are.equal(1, #list)
        -- nil collector must not error (TestDateValidation_NilCollectorSafe)
        strftime.collect_date_error(nil, strftime.new_date_error("f.md", 5, "x", "test", "bad"))
    end)

    it("format_date_error includes file:line for line>0 and omits :0: otherwise", function()
        local with_line = strftime.format_date_error(
            strftime.new_date_error("/notes/daily.md", 15, "2026-13-01", "inline due date", "bad")
        )
        assert.is_truthy(with_line:find("/notes/daily.md:15", 1, true))
        assert.is_truthy(with_line:find("inline due date", 1, true))
        assert.is_truthy(with_line:find("2026-13-01", 1, true))

        local no_line = strftime.format_date_error(
            strftime.new_date_error("/notes/project.md", 0, "2026-02-30", "frontmatter due", "bad")
        )
        assert.is_nil(no_line:find(":0:", 1, true))
        assert.is_truthy(no_line:find("/notes/project.md", 1, true))
    end)
end)
