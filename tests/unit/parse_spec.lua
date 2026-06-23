-- Ported from go/parse_test.go, go/parse_adversarial_test.go, and the inline +
-- marker sections of go/date_validation_test.go. The Go tests are the
-- behavioral contract; these assert on the Lua Task table fields.
--
-- due_date is the canonical LOCAL-NOON epoch (overview §3.1), so date assertions
-- compare via strftime.format_epoch(due_date, "%Y-%m-%d").

local parse = require("taskbuffer.parse")
local strftime = require("taskbuffer.strftime")

-- Build a parse-ctx from an inline config (the config.values shape).
local function ctx_with(cfg)
    return parse.new_parse_context(cfg or {})
end
local default_ctx = parse.new_parse_context({})

local function rm(text, path, line_number)
    return { path = path or "adversarial.md", line_number = line_number or 1, text = text }
end

-- ISO string of a Task's due_date epoch (nil when undated).
local function due_iso(task)
    if task.due_date == nil then
        return nil
    end
    return strftime.format_epoch(task.due_date, "%Y-%m-%d")
end

local function has(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

describe("parse.parse_task — core (parse_test.go)", function()
    it("simple dated task", function()
        local task = assert(parse.parse_task(rm("- [ ] Buy groceries (@[[2026-02-17]])"), default_ctx))
        assert.are.equal("Buy groceries", task.body)
        assert.are.equal("open", task.status)
        assert.are.equal("2026-02-17", due_iso(task))
        assert.are.equal("", task.due_time)
        assert.are.equal("", task.duration)
        assert.are.equal(0, #task.tags)
        assert.are.equal(0, #task.markers)
        assert.is_false(task.sort_last)
    end)

    it("task with time", function()
        local task = assert(parse.parse_task(rm("- [ ] Team meeting (@[[2026-02-17]] 16:00)"), default_ctx))
        assert.are.equal("Team meeting", task.body)
        assert.are.equal("16:00", task.due_time)
    end)

    it("task with duration", function()
        local task = assert(parse.parse_task(rm("- [ ] Meeting with Professor <90m> (@[[2026-02-17]])"), default_ctx))
        assert.are.equal("Meeting with Professor", task.body)
        assert.are.equal("90m", task.duration)
    end)

    it("task with tags", function()
        local task = assert(parse.parse_task(rm("- [ ] Run 5k #exercise #target (@[[2026-02-17]])"), default_ctx))
        assert.are.equal("Run 5k", task.body)
        assert.are.same({ "exercise", "target" }, task.tags)
    end)

    it("task with markers (original + deferral)", function()
        local task = assert(
            parse.parse_task(
                rm("- [ ] Some task (@[[2026-01-21]])::original [[2026-01-14]] ::deferral [[2026-01-21]] 12:03"),
                default_ctx
            )
        )
        assert.are.equal(2, #task.markers)
        assert.are.same({ kind = "original", date = "2026-01-14", time = "" }, task.markers[1])
        assert.are.same({ kind = "deferral", date = "2026-01-21", time = "12:03" }, task.markers[2])
    end)

    it("start/stop markers and done status", function()
        local task = assert(
            parse.parse_task(
                rm("- [x] Write report (@[[2026-01-14]]) ::start [[2026-01-14]] 15:58 ::stop [[2026-01-14]] 16:40"),
                default_ctx
            )
        )
        assert.are.equal("done", task.status)
        assert.are.equal(2, #task.markers)
        assert.are.equal("start", task.markers[1].kind)
        assert.are.equal("15:58", task.markers[1].time)
        assert.are.equal("stop", task.markers[2].kind)
        assert.are.equal("16:40", task.markers[2].time)
    end)

    it("indented / tab-led line is trimmed", function()
        local task = assert(parse.parse_task(rm("\t- [ ] Indented task (@[[2026-02-17]])\n"), default_ctx))
        assert.are.equal("Indented task", task.body)
    end)

    it("wikilinks in body survive", function()
        local task =
            assert(parse.parse_task(rm("- [ ] Visit [[The Commons]] for lunch (@[[2026-02-17]])"), default_ctx))
        assert.are.equal("Visit [[The Commons]] for lunch", task.body)
    end)

    it("alias date [[id|DATE]]", function()
        local task = assert(parse.parse_task(rm("- [ ] Aliased task (@[[1749970209-GXKH|2025-06-15]])"), default_ctx))
        assert.are.equal("2025-06-15", due_iso(task))
    end)

    it("path-prefix date [[daily/DATE]]", function()
        local task = assert(parse.parse_task(rm("- [ ] Path prefix task (@[[daily/2025-06-13]])"), default_ctx))
        assert.are.equal("2025-06-13", due_iso(task))
    end)

    it("empty date (@[[]]) is undated, no error, body keeps it", function()
        local task, err = parse.parse_task(rm("- [ ] Broken task (@[[]])"), default_ctx)
        assert.is_nil(err)
        assert.is_nil(task.due_date)
        assert.are.equal("Broken task (@[[]])", task.body)
    end)

    it("no-space markers and hyphenated tag", function()
        local task = assert(
            parse.parse_task(
                rm("- [x] Buy screws (@[[2026-01-28]]) #fish-tank::complete [[2026-01-29]] 09:16"),
                default_ctx
            )
        )
        assert.are.same({ "fish-tank" }, task.tags)
        assert.are.equal(1, #task.markers)
        assert.are.equal("complete", task.markers[1].kind)
    end)

    it("full complex line", function()
        local task = assert(
            parse.parse_task(
                rm(
                    "- [x] Rewrite About Me Section <30m> (@[[2026-01-23]] 15:00) ::start [[2026-01-23]] 15:17::complete [[2026-01-23]] 17:19"
                ),
                default_ctx
            )
        )
        assert.are.equal("done", task.status)
        assert.are.equal("Rewrite About Me Section", task.body)
        assert.are.equal("30m", task.duration)
        assert.are.equal("15:00", task.due_time)
        assert.are.equal("2026-01-23", due_iso(task))
        assert.are.equal(2, #task.markers)
        assert.are.equal("start", task.markers[1].kind)
        assert.are.equal("15:17", task.markers[1].time)
        assert.are.equal("complete", task.markers[2].kind)
        assert.are.equal("17:19", task.markers[2].time)
    end)

    it("irrelevant status", function()
        local task = assert(parse.parse_task(rm("- [-] Cancelled task (@[[2024-11-25]])"), default_ctx))
        assert.are.equal("irrelevant", task.status)
    end)

    it("marker with path-prefix date keeps stripped raw date", function()
        local task = assert(
            parse.parse_task(
                rm("- [x] Backend docs <60m> (@[[2025-05-31]])::complete [[daily/2025-06-13]] 08:50"),
                default_ctx
            )
        )
        assert.are.equal(1, #task.markers)
        assert.are.equal("2025-06-13", task.markers[1].date)
    end)

    it("undated task", function()
        local task = assert(parse.parse_task(rm("- [ ] Investigate OOM Kill Root Cause"), default_ctx))
        assert.is_nil(task.due_date)
        assert.are.equal("Investigate OOM Kill Root Cause", task.body)
        assert.are.equal("open", task.status)
        assert.are.equal("", task.due_time)
    end)

    it("undated task with tags", function()
        local task = assert(parse.parse_task(rm("- [ ] Fix memory leak #backend #urgent"), default_ctx))
        assert.is_nil(task.due_date)
        assert.are.equal("Fix memory leak", task.body)
        assert.are.same({ "backend", "urgent" }, task.tags)
    end)

    it("undated task with duration", function()
        local task = assert(parse.parse_task(rm("- [ ] Research caching strategies <60m>"), default_ctx))
        assert.is_nil(task.due_date)
        assert.are.equal("Research caching strategies", task.body)
        assert.are.equal("60m", task.duration)
    end)

    it("no checkbox returns nil + error", function()
        local task, err = parse.parse_task(rm("Not a task line"), default_ctx)
        assert.is_nil(task)
        assert.is_truthy(err)
    end)
end)

describe("parse.parse_tasks", function()
    it("skips unparseable lines", function()
        local matches = {
            rm("- [ ] Good task (@[[2026-02-17]])", "a.md", 1),
            rm("not a task line at all", "b.md", 2),
            rm("- [ ] Also good (@[[2026-02-18]])", "c.md", 3),
        }
        local tasks = parse.parse_tasks(matches, default_ctx)
        assert.are.equal(2, #tasks)
    end)
end)

describe("parse — config-driven date wrappers (parse_test.go)", function()
    local ctx3 = ctx_with({ formats = { date_wrapper = { "(@[[", "]]", ")" } } })

    it("3-element wrapper with time", function()
        local task = assert(parse.parse_task(rm("- [ ] Lunch with Karah (@[[2026-03-04]] 13:00)"), ctx3))
        assert.are.equal("Lunch with Karah", task.body)
        assert.are.equal("2026-03-04", due_iso(task))
        assert.are.equal("13:00", task.due_time)
    end)

    it("3-element wrapper without time", function()
        local task = assert(parse.parse_task(rm("- [ ] Buy groceries (@[[2026-03-04]])"), ctx3))
        assert.are.equal("Buy groceries", task.body)
        assert.are.equal("2026-03-04", due_iso(task))
        assert.are.equal("", task.due_time)
    end)
end)

describe("parse — custom date/time formats (parse_test.go)", function()
    it("US date %m/%d/%Y", function()
        local ctx = ctx_with({ formats = { date = "%m/%d/%Y", date_wrapper = { "(@[[", "]]", ")" } } })
        local task = assert(parse.parse_task(rm("- [ ] Task (@[[03/04/2026]])"), ctx))
        assert.are.equal("Task", task.body)
        assert.are.equal("2026-03-04", due_iso(task))
    end)

    it("US date with 24h time", function()
        local ctx = ctx_with({ formats = { date = "%m/%d/%Y", time = "%H:%M", date_wrapper = { "(@[[", "]]", ")" } } })
        local task = assert(parse.parse_task(rm("- [ ] Task (@[[03/04/2026]] 13:00)"), ctx))
        assert.are.equal("2026-03-04", due_iso(task))
        assert.are.equal("13:00", task.due_time)
    end)

    it("12-hour time keeps the verbatim '1:00 PM'", function()
        local ctx =
            ctx_with({ formats = { date = "%Y-%m-%d", time = "%I:%M %p", date_wrapper = { "(@[[", "]]", ")" } } })
        local task = assert(parse.parse_task(rm("- [ ] Task (@[[2026-03-04]] 1:00 PM)"), ctx))
        assert.are.equal("1:00 PM", task.due_time)
    end)

    it("dot separator is literal, not wildcard", function()
        local ctx = ctx_with({ formats = { date = "%d.%m.%Y", date_wrapper = { "(@[[", "]]", ")" } } })
        local ok = assert(parse.parse_task(rm("- [ ] Task (@[[04.03.2026]])"), ctx))
        assert.are.equal("2026-03-04", due_iso(ok))
        -- "04X03X2026" must NOT match -> undated, no error.
        local task2, err = parse.parse_task(rm("- [ ] Task (@[[04X03X2026]])"), ctx)
        assert.is_nil(err)
        assert.is_nil(task2.due_date)
    end)

    it("compact format %Y%m%d", function()
        local ctx = ctx_with({ formats = { date = "%Y%m%d", date_wrapper = { "(@[[", "]]", ")" } } })
        local task = assert(parse.parse_task(rm("- [ ] Task (@[[20260304]])"), ctx))
        assert.are.equal("2026-03-04", due_iso(task))
    end)

    it("date in body is not captured", function()
        local ctx = ctx_with({ formats = { date = "%m/%d/%Y", date_wrapper = { "(@[[", "]]", ")" } } })
        local task = assert(parse.parse_task(rm("- [ ] Meeting re: 01/01/2026 invoice (@[[03/04/2026]])"), ctx))
        assert.are.equal("Meeting re: 01/01/2026 invoice", task.body)
        assert.are.equal("2026-03-04", due_iso(task))
    end)

    it("markers with custom format keep raw date/time", function()
        local ctx =
            ctx_with({ formats = { date = "%m/%d/%Y", time = "%I:%M %p", date_wrapper = { "(@[[", "]]", ")" } } })
        local task = assert(
            parse.parse_task(
                rm("- [x] Task (@[[03/04/2026]]) ::start [[03/04/2026]] 1:00 PM ::complete [[03/04/2026]] 2:30 PM"),
                ctx
            )
        )
        assert.are.equal(2, #task.markers)
        assert.are.same({ kind = "start", date = "03/04/2026", time = "1:00 PM" }, task.markers[1])
        assert.are.same({ kind = "complete", date = "03/04/2026", time = "2:30 PM" }, task.markers[2])
    end)

    it("wikilink alias with custom format", function()
        local ctx = ctx_with({ formats = { date = "%m/%d/%Y", date_wrapper = { "(@[[", "]]", ")" } } })
        local task = assert(parse.parse_task(rm("- [ ] Task (@[[some-id|03/04/2026]])"), ctx))
        assert.are.equal("2026-03-04", due_iso(task))
    end)
end)

describe("parse — adversarial (parse_adversarial_test.go)", function()
    it("longest-first prefix prevents short checkbox shadowing long", function()
        local cases = {
            { cb = { open = "- [ ]", bullet = "- " }, input = "- [ ] Real task", status = "open", body = "Real task" },
            { cb = { open = "* [ ]", bullet = "* " }, input = "* [ ] Star task", status = "open", body = "Star task" },
            { cb = { open = "* [ ]", done = "* [x]" }, input = "* [x] Done", status = "done", body = "Done" },
        }
        for _, c in ipairs(cases) do
            local ctx = ctx_with({ formats = { checkbox = c.cb } })
            local task = assert(parse.parse_task(rm(c.input), ctx))
            assert.are.equal(c.status, task.status)
            assert.are.equal(c.body, task.body)
        end
    end)

    it("empty checkbox string is filtered; non-task lines error", function()
        local ctx = ctx_with({ formats = { checkbox = { open = "", done = "- [x]" } } })
        for _, input in ipairs({ "Hello world", "# Not a task", "" }) do
            local task, err = parse.parse_task(rm(input), ctx)
            assert.is_nil(task)
            assert.is_truthy(err)
        end
    end)

    it("whitespace-only checkbox is filtered; indented lines error", function()
        local ctx = ctx_with({ formats = { checkbox = { open = "   " } } })
        for _, input in ipairs({ "    code block line", "   - nested item" }) do
            local task, err = parse.parse_task(rm(input), ctx)
            assert.is_nil(task)
            assert.is_truthy(err)
        end
    end)

    it("newline-in-checkbox never matches a single line", function()
        local ctx = ctx_with({ formats = { checkbox = { open = "- [\n]" } } })
        local task, err = parse.parse_task(rm("- [ ] Normal task"), ctx)
        assert.is_nil(task)
        assert.is_truthy(err)
    end)

    it("duplicate checkbox resolves deterministically to alpha-first name", function()
        local cfg = { formats = { checkbox = { alpha = "- [ ]", charlie = "- [ ]", bravo = "- [x]" } } }
        local statuses = {}
        for _ = 1, 50 do
            local ctx = ctx_with(cfg)
            local task = assert(parse.parse_task(rm("- [ ] Test task"), ctx))
            statuses[task.status] = true
        end
        assert.is_true(statuses["alpha"])
        assert.is_nil(statuses["charlie"])
    end)

    it("config fallbacks set default tag/marker prefixes", function()
        local cases = {
            { cfg = {}, tag = "#", marker = "::" },
            { cfg = { formats = { date_wrapper = { "{" } } }, tag = "#", marker = "::" },
            { cfg = { formats = { date_wrapper = { "", "" } } }, tag = "#", marker = "::" },
            { cfg = { formats = { tag_prefix = "+" } }, tag = "+", marker = "::" },
        }
        for _, c in ipairs(cases) do
            local ctx = ctx_with(c.cfg)
            assert.are.equal(c.tag, ctx.tag_prefix)
            assert.are.equal(c.marker, ctx.marker_prefix)
        end
    end)

    it("single-element DateWrapper falls back to default and still parses", function()
        local ctx = ctx_with({ formats = { date_wrapper = { "{" } } })
        local task = assert(parse.parse_task(rm("- [ ] Task (@[[2026-02-17]])"), ctx))
        assert.are.equal("2026-02-17", due_iso(task))
    end)

    it("marker prefix in body text (default ::) does not truncate undated body", function()
        local cases = {
            { input = "- [ ] Fix std::vector crash", body = "Fix std::vector crash" },
            { input = "- [ ] Refactor Vec::new() call", body = "Refactor Vec::new() call" },
            { input = "- [ ] Check http://localhost::8080/health", body = "Check http://localhost::8080/health" },
            { input = "- [ ] Fix std::vector crash (@[[2026-02-17]])", body = "Fix std::vector crash" },
        }
        for _, c in ipairs(cases) do
            local task = assert(parse.parse_task(rm(c.input), default_ctx))
            assert.are.equal(c.body, task.body)
        end
    end)

    it("single-colon marker prefix does not truncate 'Note: fix bug'", function()
        local ctx = ctx_with({ formats = { marker_prefix = ":" } })
        local undated = assert(parse.parse_task(rm("- [ ] Note: fix bug"), ctx))
        assert.are.equal("Note: fix bug", undated.body)
        local dated = assert(parse.parse_task(rm("- [ ] Note: fix bug (@[[2026-02-17]])"), ctx))
        assert.are.equal("Note: fix bug", dated.body)
    end)

    it("markers ignore custom wrapper (always [[ ]])", function()
        local ctx = ctx_with({ formats = { date_wrapper = { "{", "}" } } })
        local ok = assert(parse.parse_task(rm("- [ ] Task {2026-02-17} ::start [[2026-02-17]] 15:00"), ctx))
        assert.are.equal(1, #ok.markers)
        assert.are.equal("start", ok.markers[1].kind)
        -- Markers written with the custom wrapper silently do not parse.
        local none, err = parse.parse_task(rm("- [ ] Task {2026-02-17} ::start {2026-02-17} 15:00"), ctx)
        assert.is_nil(err)
        assert.are.equal(0, #none.markers)
    end)

    it("multiple date groups — first (leftmost) wins, body is before it", function()
        local task = assert(parse.parse_task(rm("- [ ] Compare (@[[2026-02-17]]) vs (@[[2026-03-01]])"), default_ctx))
        assert.are.equal("2026-02-17", due_iso(task))
        assert.are.equal("Compare", task.body)
    end)

    it("invalid inline date values error in non-strict mode (valid pass)", function()
        local cases = {
            { input = "- [ ] Task (@[[2026-13-01]])", want_err = true },
            { input = "- [ ] Task (@[[2026-01-32]])", want_err = true },
            { input = "- [ ] Task (@[[2026-00-15]])", want_err = true },
            { input = "- [ ] Task (@[[2024-02-29]])", want_err = false },
            { input = "- [ ] Task (@[[2025-02-29]])", want_err = true },
        }
        for _, c in ipairs(cases) do
            local task, err = parse.parse_task(rm(c.input), default_ctx)
            if c.want_err then
                assert.is_nil(task)
                assert.is_truthy(err)
            else
                assert.is_truthy(task)
                assert.is_nil(err)
            end
        end
    end)

    it("documents tag/marker prefix collision leak (::)", function()
        local ctx = ctx_with({ formats = { tag_prefix = "::", marker_prefix = "::" } })
        local task = assert(parse.parse_task(rm("- [ ] Some task (@[[2026-02-17]]) ::start [[2026-02-17]] 15:00"), ctx))
        assert.is_true(has(task.tags, "start"))
    end)

    it("documents '[' tag-prefix capturing wikilinks", function()
        local ctx = ctx_with({ formats = { tag_prefix = "[" } })
        local task = assert(parse.parse_task(rm("- [ ] Visit [[Commons]] for lunch (@[[2026-02-17]])"), ctx))
        assert.is_true(has(task.tags, "Commons"))
    end)
end)

describe("parse — strict date validation (date_validation_test.go)", function()
    local invalid_dates = {
        "2026-00-15",
        "2026-13-01",
        "2026-99-01",
        "2026-01-00",
        "2026-01-32",
        "2026-01-99",
        "2026-04-31",
        "2026-06-31",
        "2026-09-31",
        "2026-11-31",
        "2026-02-30",
        "2026-02-31",
        "2025-02-29",
        "2100-02-29",
    }
    local valid_dates = {
        "2026-01-01",
        "2026-12-31",
        "2025-02-28",
        "2024-02-29",
        "2000-02-29",
        "2026-04-30",
        "2026-06-30",
    }

    local function strict_ctx()
        local ctx = ctx_with({ strict = true })
        ctx.date_errors = {}
        return ctx
    end

    it("strict inline: no error returned, due nil, one DateError per invalid date", function()
        for _, ds in ipairs(invalid_dates) do
            local ctx = strict_ctx()
            local task, err = parse.parse_task(rm("- [ ] Task (@[[" .. ds .. "]])", "adversarial.md", 1), ctx)
            assert.is_nil(err)
            assert.is_truthy(task)
            assert.is_nil(task.due_date)
            assert.are.equal(1, #ctx.date_errors)
            local de = ctx.date_errors[1]
            assert.are.equal(ds, de.date_str)
            assert.are.equal("inline due date", de.context)
            assert.are.equal("adversarial.md", de.file_path)
            assert.are.equal(1, de.line_number)
        end
    end)

    it("strict inline preserves body and tags despite invalid date", function()
        local ctx = strict_ctx()
        local task = assert(parse.parse_task(rm("- [ ] Important task #work (@[[2026-13-01]])"), ctx))
        assert.are.equal("Important task", task.body)
        assert.are.same({ "work" }, task.tags)
        assert.is_nil(task.due_date)
    end)

    it("non-strict inline: invalid dates error", function()
        for _, ds in ipairs(invalid_dates) do
            local task, err = parse.parse_task(rm("- [ ] Task (@[[" .. ds .. "]])"), default_ctx)
            assert.is_nil(task)
            assert.is_truthy(err)
        end
    end)

    it("strict inline: valid dates set due and collect no errors", function()
        for _, ds in ipairs(valid_dates) do
            local ctx = strict_ctx()
            local task = assert(parse.parse_task(rm("- [ ] Task (@[[" .. ds .. "]])"), ctx))
            assert.is_truthy(task.due_date)
            assert.are.equal(0, #ctx.date_errors)
        end
    end)

    it("strict marker: stores raw date, collects 'marker (start)' error, inline still parsed", function()
        for _, ds in ipairs(invalid_dates) do
            local ctx = strict_ctx()
            local task =
                assert(parse.parse_task(rm("- [ ] Task (@[[2026-01-15]]) ::start [[" .. ds .. "]] 10:00"), ctx))
            assert.is_truthy(task.due_date)
            assert.are.equal(1, #task.markers)
            assert.are.equal(ds, task.markers[1].date)
            assert.are.equal(1, #ctx.date_errors)
            assert.are.equal("marker (start)", ctx.date_errors[1].context)
        end
    end)

    it("non-strict marker: stores raw invalid date, no complaint", function()
        local task =
            assert(parse.parse_task(rm("- [ ] Task (@[[2026-01-15]]) ::start [[2026-13-45]] 10:00"), default_ctx))
        assert.are.equal(1, #task.markers)
        assert.are.equal("2026-13-45", task.markers[1].date)
    end)

    it("strict marker: valid marker dates collect no errors", function()
        for _, ds in ipairs(valid_dates) do
            local ctx = strict_ctx()
            assert(parse.parse_task(rm("- [ ] Task (@[[2026-01-15]]) ::complete [[" .. ds .. "]] 14:00"), ctx))
            assert.are.equal(0, #ctx.date_errors)
        end
    end)

    it("strict: multiple invalid markers collect one error each, both stored", function()
        local ctx = strict_ctx()
        local task = assert(
            parse.parse_task(
                rm("- [ ] Task (@[[2026-01-15]]) ::start [[2026-13-01]] 10:00 ::stop [[2026-00-15]] 11:00"),
                ctx
            )
        )
        assert.are.equal(2, #task.markers)
        assert.are.equal(2, #ctx.date_errors)
        assert.are.equal("marker (start)", ctx.date_errors[1].context)
        assert.are.equal("marker (stop)", ctx.date_errors[2].context)
    end)

    it("strict: errors accumulate across inline and marker surfaces", function()
        local ctx = strict_ctx()
        parse.parse_task(rm("- [ ] Task one (@[[2026-13-01]])"), ctx)
        parse.parse_task(rm("- [ ] Task two (@[[2026-01-15]]) ::start [[2026-04-31]] 10:00"), ctx)
        assert.are.equal(2, #ctx.date_errors)
        local contexts = {}
        for _, e in ipairs(ctx.date_errors) do
            contexts[e.context] = true
        end
        assert.is_true(contexts["inline due date"])
        assert.is_true(contexts["marker (start)"])
    end)

    it("strict does not suppress missing-checkbox errors", function()
        local ctx = strict_ctx()
        local task, err = parse.parse_task(rm("Not a task line"), ctx)
        assert.is_nil(task)
        assert.is_truthy(err)
        assert.are.equal(0, #ctx.date_errors)
    end)

    it("nil collector in strict mode does not error on invalid date", function()
        local ctx = ctx_with({ strict = true }) -- date_errors stays nil
        local task, err = parse.parse_task(rm("- [ ] Task (@[[2026-13-01]])"), ctx)
        assert.is_nil(err)
        assert.is_truthy(task)
        assert.is_nil(task.due_date)
    end)
end)
