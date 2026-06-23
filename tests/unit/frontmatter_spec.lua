-- Ported from go/frontmatter_test.go, go/fm_due_e2e_test.go, and the frontmatter
-- + ScanProjects cases of go/date_validation_test.go.
--
-- Since the Lua FM module reads files directly (no rg/Scan), the e2e pipeline
-- cases construct Task tables by hand instead of parsing markdown bodies. Each
-- fixture .md is written into a tempfile; M.reset() runs at the start of every
-- pipeline so a path reused across cases never returns a stale cache entry.

local fm = require("taskbuffer.frontmatter")
local strftime = require("taskbuffer.strftime")

-- ── fixture helpers ───────────────────────────────────────────────────────────

local function write_file(content)
    local p = vim.fn.tempname() .. ".md"
    local f = assert(io.open(p, "w"))
    f:write(content)
    f:close()
    return p
end

local function overwrite(p, content)
    local f = assert(io.open(p, "w"))
    f:write(content)
    f:close()
end

-- Canonical Task table (snake_case). due_date is a noon epoch | nil.
local function task(file_path, body, opts)
    opts = opts or {}
    return {
        file_path = file_path,
        line_number = opts.line or 1,
        body = body,
        due_date = opts.due_date, -- nil = undated, else epoch
        due_time = opts.due_time or "",
        duration = "",
        tags = opts.tags or {},
        status = opts.status or "open",
        markers = {},
        sort_last = false,
    }
end

local SPEC = strftime.compile("%Y-%m-%d")

-- Build an inline-dated noon epoch (mirrors what parse.lua would produce).
local function epoch(y, m, d)
    return strftime.date_to_epoch(y, m, d)
end

-- Read back an epoch as YYYY-MM-DD for assertions.
local function iso(e)
    return strftime.format_epoch(e, "%Y-%m-%d")
end

-- The cmdList-style pipeline: reset -> merge_tags -> filter_completed -> merge_due.
local function full_pipeline(tasks, fm_cfg, date_errors)
    fm.reset()
    fm.merge_tags(tasks)
    tasks = fm.filter_completed(tasks, fm_cfg)
    fm.merge_due(tasks, fm_cfg, "%Y-%m-%d", date_errors)
    return tasks
end

local function find(tasks, body)
    for _, t in ipairs(tasks) do
        if t.body == body then
            return t
        end
    end
    return nil
end

-- =============================================================================
-- parse_frontmatter / tags  (frontmatter_test.go)
-- =============================================================================

describe("parse_frontmatter + tags", function()
    before_each(function()
        fm.reset()
    end)

    it("parses block-list tags", function()
        local p = write_file("---\ntags:\n  - sspi\n  - project\n---\n# Content\n")
        assert.are.same({ "sspi", "project" }, fm.tags(p))
    end)

    it("returns no tags when there is no frontmatter", function()
        local p = write_file("# Just a heading\nSome content\n")
        assert.is_nil(fm.parse_frontmatter(p))
        assert.are.same({}, fm.tags(p))
    end)

    it("returns empty tags for `tags: []`", function()
        local p = write_file("---\ntags: []\n---\n")
        assert.are.same({}, fm.tags(p))
    end)

    it("returns empty tags when there is no tags field", function()
        local p = write_file("---\ntitle: My Note\n---\n")
        assert.are.same({}, fm.tags(p))
    end)

    it("parses inline-flow tags `[a, b]`", function()
        local p = write_file("---\ntags: [alpha, beta]\n---\n")
        assert.are.same({ "alpha", "beta" }, fm.tags(p))
    end)

    it("ignores tags given as a scalar string", function()
        local p = write_file("---\ntags: single-string-tag\n---\n")
        assert.are.same({}, fm.tags(p))
    end)

    it("returns a stale cached value within one refresh, fresh after reset", function()
        local p = write_file("---\ntags:\n  - cached\n---\n")
        local t1 = fm.tags(p)
        overwrite(p, "---\ntags:\n  - different\n---\n")
        local t2 = fm.tags(p) -- cached, no reset between reads
        assert.are.same({ "cached" }, t1)
        assert.are.same({ "cached" }, t2)
        fm.reset()
        assert.are.same({ "different" }, fm.tags(p))
    end)
end)

-- =============================================================================
-- get_string / custom keys  (frontmatter_test.go)
-- =============================================================================

describe("get_string", function()
    before_each(function()
        fm.reset()
    end)

    it("reads a custom due key and ignores the default", function()
        local p = write_file("---\ndeadline: 2026-04-01\ntags:\n  - work\n---\n")
        local f = fm.parse_frontmatter(p)
        assert.are.equal("2026-04-01", fm.get_string(f, "deadline"))
        assert.are.equal("", fm.get_string(f, "due"))
    end)

    it("reads a custom status key", function()
        local p = write_file("---\nstate: finished\n---\n")
        local f = fm.parse_frontmatter(p)
        assert.are.equal("finished", fm.get_string(f, "state"))
    end)

    it("returns the verbatim quoted date+time string", function()
        local p = write_file("---\ndue: \"2026-05-10 14:30\"\n---\n")
        local f = fm.parse_frontmatter(p)
        assert.are.equal("2026-05-10 14:30", fm.get_string(f, "due"))
    end)
end)

-- =============================================================================
-- merge_tags  (frontmatter_test.go)
-- =============================================================================

describe("merge_tags", function()
    before_each(function()
        fm.reset()
    end)

    it("unions and deduplicates, inline first then FM appended", function()
        local p = write_file("---\ntags:\n  - project\n  - sspi\n---\n")
        local tasks = { task(p, "t", { tags = { "sspi", "inline" } }) }
        fm.merge_tags(tasks)
        assert.are.same({ "sspi", "inline", "project" }, tasks[1].tags)
    end)
end)

-- =============================================================================
-- merge_due  (frontmatter_test.go)
-- =============================================================================

describe("merge_due", function()
    before_each(function()
        fm.reset()
    end)

    it("inherits the FM due when the task has no inline date", function()
        local p = write_file("---\ndue: 2026-05-10\ntags:\n  - work\n---\n")
        local tasks = { task(p, "undated task") }
        fm.merge_due(tasks, {}, "%Y-%m-%d", nil)
        assert.is_not_nil(tasks[1].due_date)
        assert.are.equal("2026-05-10", iso(tasks[1].due_date))
    end)

    it("lets an inline date win over the FM due", function()
        local p = write_file("---\ndue: 2026-05-10\n---\n")
        local tasks = { task(p, "dated", { due_date = epoch(2026, 3, 15) }) }
        fm.merge_due(tasks, {}, "%Y-%m-%d", nil)
        assert.are.equal("2026-03-15", iso(tasks[1].due_date))
    end)

    it("does not inherit when inherit_due is false", function()
        local p = write_file("---\ndue: 2026-05-10\n---\n")
        local tasks = { task(p, "undated") }
        fm.merge_due(tasks, { inherit_due = false }, "%Y-%m-%d", nil)
        assert.is_nil(tasks[1].due_date)
    end)

    it("respects require_tags (all must be present)", function()
        local has = write_file("---\ndue: 2026-05-10\ntags:\n  - project\n---\n")
        local missing = write_file("---\ndue: 2026-05-10\ntags:\n  - notes\n---\n")
        local tasks = { task(has, "in project file"), task(missing, "in notes file") }
        fm.merge_due(tasks, { require_tags = { "project" } }, "%Y-%m-%d", nil)
        assert.is_not_nil(tasks[1].due_date)
        assert.is_nil(tasks[2].due_date)
    end)

    it("inherits the time portion of a quoted date+time", function()
        local p = write_file("---\ndue: \"2026-05-10 14:30\"\n---\n")
        local tasks = { task(p, "timed") }
        fm.merge_due(tasks, {}, "%Y-%m-%d", nil)
        assert.is_not_nil(tasks[1].due_date)
        assert.are.equal("14:30", tasks[1].due_time)
    end)

    it("reads a custom due key", function()
        local p = write_file("---\ndeadline: 2026-06-01\n---\n")
        local tasks = { task(p, "custom key task") }
        fm.merge_due(tasks, { due_key = "deadline" }, "%Y-%m-%d", nil)
        assert.is_not_nil(tasks[1].due_date)
        assert.are.equal("2026-06-01", iso(tasks[1].due_date))
    end)
end)

-- =============================================================================
-- filter_completed  (frontmatter_test.go)
-- =============================================================================

describe("filter_completed", function()
    before_each(function()
        fm.reset()
    end)

    it("excludes undated tasks from a done file", function()
        local p = write_file("---\ndue: 2026-05-01\nstatus: done\ntags:\n  - project\n---\n")
        local tasks = { task(p, "undated one", { line = 5 }), task(p, "undated two", { line = 6 }) }
        local result = fm.filter_completed(tasks, {})
        assert.are.equal(0, #result)
    end)

    it("keeps an inline-dated task from a done file", function()
        local p = write_file("---\ndue: 2026-05-01\nstatus: done\n---\n")
        local tasks = {
            task(p, "undated", { line = 5 }),
            task(p, "inline dated", { line = 6, due_date = epoch(2026, 3, 15) }),
        }
        local result = fm.filter_completed(tasks, {})
        assert.are.equal(1, #result)
        assert.are.equal("inline dated", result[1].body)
    end)

    it("honors custom done values", function()
        local p = write_file("---\ndue: 2026-05-01\nstatus: archived\n---\n")
        local tasks = { task(p, "in archived file", { line = 5 }) }

        -- Default done values do not include "archived".
        assert.are.equal(1, #fm.filter_completed(tasks, {}))

        fm.reset()
        local custom = fm.filter_completed(tasks, { done_values = { "archived", "done" } })
        assert.are.equal(0, #custom)
    end)

    it("keeps tasks from an active (non-done) file", function()
        local p = write_file("---\ndue: 2026-05-01\nstatus: active\n---\n")
        local tasks = { task(p, "from active file", { line = 5 }) }
        assert.are.equal(1, #fm.filter_completed(tasks, {}))
    end)
end)

-- =============================================================================
-- Full pipeline (fm_due_e2e_test.go) — fixtures built inline
-- =============================================================================

describe("full pipeline", function()
    it("basic inheritance: undated inherit, inline wins", function()
        local p = write_file("---\ndue: \"2026-04-15\"\ntags:\n  - work\n---\n")
        local tasks = full_pipeline({
            task(p, "Undated task one"),
            task(p, "Undated task two"),
            task(p, "Dated task with inline", { due_date = epoch(2026, 3, 1) }),
        }, {})
        assert.are.equal(3, #tasks)
        assert.are.equal("2026-04-15", iso(find(tasks, "Undated task one").due_date))
        assert.are.equal("2026-04-15", iso(find(tasks, "Undated task two").due_date))
        assert.are.equal("2026-03-01", iso(find(tasks, "Dated task with inline").due_date))
    end)

    it("a completed file filters its undated tasks, inline survives", function()
        local p = write_file("---\ndue: 2026-05-01\nstatus: done\n---\n")
        local tasks = full_pipeline({
            task(p, "Leftover undated task"),
            task(p, "Inline dated", { due_date = epoch(2026, 3, 1) }),
        }, {})
        assert.are.equal(1, #tasks)
        assert.are.equal("Inline dated", tasks[1].body)
    end)

    it("status: complete also filters (default done_values)", function()
        local p = write_file("---\ndue: 2026-05-01\nstatus: complete\n---\n")
        local tasks = full_pipeline({ task(p, "undated in complete file") }, {})
        assert.are.equal(0, #tasks)
    end)

    it("an active file is not filtered and still inherits", function()
        local p = write_file("---\ndue: \"2026-04-10\"\nstatus: active\n---\n")
        local tasks = full_pipeline({
            task(p, "Undated one"),
            task(p, "Undated two"),
        }, {})
        assert.are.equal(2, #tasks)
        for _, t in ipairs(tasks) do
            assert.are.equal("2026-04-10", iso(t.due_date))
        end
    end)

    it("no due key leaves tasks undated", function()
        local p = write_file("---\ntitle: x\ntags:\n  - work\n---\n")
        local tasks = full_pipeline({ task(p, "undated") }, {})
        assert.is_nil(tasks[1].due_date)
    end)

    it("no frontmatter at all leaves tasks undated", function()
        local p = write_file("# heading\n")
        local tasks = full_pipeline({ task(p, "undated") }, {})
        assert.is_nil(tasks[1].due_date)
    end)

    it("inherit_due=false: filter still runs, inheritance does not", function()
        local p = write_file("---\ndue: 2026-05-01\nstatus: done\n---\n")
        local tasks = full_pipeline({
            task(p, "Undated A"),
            task(p, "Undated B"),
            task(p, "Inline C", { due_date = epoch(2026, 3, 1) }),
            task(p, "Inline D", { due_date = epoch(2026, 3, 2) }),
        }, { inherit_due = false })
        -- 2 undated filtered (done file), 2 inline survive; none inherit.
        assert.are.equal(2, #tasks)
    end)

    it("custom due key: inherits from 'deadline', default ignores it", function()
        local p = write_file("---\ndeadline: \"2026-06-01\"\ntags:\n  - project\n---\n")

        local custom = full_pipeline({ task(p, "deadline task") }, { due_key = "deadline" })
        assert.are.equal("2026-06-01", iso(custom[1].due_date))

        local default = full_pipeline({ task(p, "deadline task") }, {})
        assert.is_nil(default[1].due_date)
    end)

    it("custom status key + done values filters undated", function()
        local p = write_file("---\ndeadline: 2026-06-15\nstate: archived\ntags:\n  - old\n---\n")
        local tasks = full_pipeline({
            task(p, "Task in archived file"),
            task(p, "Inline dated in archived", { due_date = epoch(2026, 8, 1) }),
        }, { due_key = "deadline", status_key = "state", done_values = { "archived" } })
        assert.are.equal(1, #tasks)
        assert.are.equal("Inline dated in archived", tasks[1].body)
    end)

    it("require_tags: multiple must all match", function()
        local p = write_file("---\ndue: \"2026-05-20\"\ntags:\n  - project\n  - important\n---\n")
        local both = full_pipeline({ task(p, "t") }, { require_tags = { "project", "important" } })
        assert.is_not_nil(both[1].due_date)

        local partial = full_pipeline({ task(p, "t") }, { require_tags = { "project", "secret" } })
        assert.is_nil(partial[1].due_date)
    end)

    it("empty require_tags allows all files to inherit", function()
        local p = write_file("---\ndue: \"2026-04-15\"\ntags:\n  - work\n---\n")
        local tasks = full_pipeline({ task(p, "undated") }, { require_tags = {} })
        assert.is_not_nil(tasks[1].due_date)
    end)

    it("inherits both date and time from the FM", function()
        local p = write_file("---\ndue: \"2026-04-15 14:30\"\ntags:\n  - meeting\n---\n")
        local tasks = full_pipeline({ task(p, "Undated inheriting time") }, {})
        assert.are.equal("2026-04-15", iso(tasks[1].due_date))
        assert.are.equal("14:30", tasks[1].due_time)
    end)

    it("inherits a bare (unquoted) YAML date", function()
        local p = write_file("---\ndue: 2026-04-15\ntags:\n  - work\n---\n")
        local tasks = full_pipeline({ task(p, "bare date task") }, {})
        assert.are.equal("2026-04-15", iso(tasks[1].due_date))
    end)

    it("normalizes a bare non-zero-padded YAML date (yaml.v3 parity)", function()
        local p = write_file("---\ndue: 2026-4-1\ntags:\n  - work\n---\n")
        local tasks = full_pipeline({ task(p, "non-padded date") }, {})
        assert.is_not_nil(tasks[1].due_date)
        assert.are.equal("2026-04-01", iso(tasks[1].due_date))
    end)

    it("filter runs BEFORE inherit (undated-from-done dropped)", function()
        local p = write_file("---\ndue: 2026-05-01\nstatus: done\n---\n")
        local build = function()
            return {
                task(p, "undated 1"),
                task(p, "undated 2"),
                task(p, "inline", { due_date = epoch(2026, 3, 1) }),
            }
        end
        -- Correct order.
        local correct = full_pipeline(build(), {})
        assert.are.equal(1, #correct)

        -- Wrong order: inherit first, then filter -> undated kept their dates.
        fm.reset()
        local wrong = build()
        fm.merge_tags(wrong)
        fm.merge_due(wrong, {}, "%Y-%m-%d", nil)
        wrong = fm.filter_completed(wrong, {})
        assert.is_true(#wrong > #correct)
    end)

    it("a file with due but no status field still inherits", function()
        local p = write_file("---\ndue: 2026-09-01\n---\n")
        local tasks = full_pipeline({ task(p, "no status") }, {})
        assert.are.equal(1, #tasks)
        assert.is_not_nil(tasks[1].due_date)
    end)

    it("a done status with no due field does not filter", function()
        local p = write_file("---\nstatus: done\n---\n")
        local tasks = full_pipeline({ task(p, "done no due") }, {})
        assert.are.equal(1, #tasks)
    end)

    it("done value matching is case-insensitive", function()
        local p = write_file("---\ndue: 2026-03-01\nstatus: DONE\n---\n")
        local tasks = full_pipeline({ task(p, "should be filtered") }, {})
        assert.are.equal(0, #tasks)
    end)

    it("empty vault produces no tasks", function()
        local tasks = full_pipeline({}, {})
        assert.are.equal(0, #tasks)
    end)
end)

-- =============================================================================
-- project_task (ScanProjects FM half: scan.go + fm_due_e2e_test.go)
-- =============================================================================

describe("project_task", function()
    before_each(function()
        fm.reset()
    end)

    it("builds a SortLast task from a tagged project file", function()
        local p = write_file("---\ntags:\n  - project\ndue: 2026-07-01\n---\n- [ ] A task\n")
        local t = fm.project_task(p, {}, "%Y-%m-%d", nil)
        assert.is_not_nil(t)
        assert.is_true(t.sort_last)
        assert.are.equal(1, t.line_number)
        assert.are.equal("open", t.status)
        assert.are.equal("2026-07-01", iso(t.due_date))
        assert.are.same({ "project" }, t.tags)
    end)

    it("uses the basename without .md as the body", function()
        local p = write_file("---\ntags:\n  - project\ndue: 2026-07-01\n---\n")
        local t = fm.project_task(p, {}, "%Y-%m-%d", nil)
        local expected = (p:match("([^/]+)$"):gsub("%.md$", ""))
        assert.are.equal(expected, t.body)
    end)

    it("returns nil when the file is not tagged project", function()
        local p = write_file("---\ntags:\n  - work\ndue: 2026-07-01\n---\n")
        assert.is_nil(fm.project_task(p, {}, "%Y-%m-%d", nil))
    end)

    it("returns nil when there is no due date", function()
        local p = write_file("---\ntags:\n  - project\n---\n")
        assert.is_nil(fm.project_task(p, {}, "%Y-%m-%d", nil))
    end)

    it("honors custom done values (shipped not done by default)", function()
        local p = write_file("---\ntags:\n  - project\ndue: 2026-07-01\nstatus: shipped\n---\n")
        assert.is_not_nil(fm.project_task(p, {}, "%Y-%m-%d", nil))
        fm.reset()
        assert.is_nil(fm.project_task(p, { done_values = { "shipped", "done" } }, "%Y-%m-%d", nil))
    end)

    it("honors a custom due key", function()
        local p = write_file("---\ntags:\n  - project\ndeadline: 2026-07-01\nstatus: active\n---\n")
        assert.is_nil(fm.project_task(p, {}, "%Y-%m-%d", nil)) -- default 'due' missing
        fm.reset()
        local t = fm.project_task(p, { due_key = "deadline" }, "%Y-%m-%d", nil)
        assert.is_not_nil(t)
        assert.are.equal("2026-07-01", iso(t.due_date))
    end)

    it("honors a custom status key", function()
        local p = write_file("---\ntags:\n  - project\ndue: 2026-07-01\nstate: retired\n---\n")
        assert.is_not_nil(fm.project_task(p, {}, "%Y-%m-%d", nil)) -- default status not found
        fm.reset()
        assert.is_nil(fm.project_task(p, { status_key = "state", done_values = { "retired" } }, "%Y-%m-%d", nil))
    end)
end)

-- =============================================================================
-- Strict date validation (date_validation_test.go)
-- =============================================================================

describe("date validation", function()
    local invalid = {
        "2026-00-15", "2026-13-01", "2026-99-01",
        "2026-01-00", "2026-01-32", "2026-01-99",
        "2026-04-31", "2026-06-31", "2026-09-31", "2026-11-31",
        "2026-02-30", "2026-02-31", "2025-02-29", "2100-02-29",
    }
    local valid = {
        "2026-01-01", "2026-12-31", "2025-02-28",
        "2024-02-29", "2000-02-29", "2026-04-30", "2026-06-30",
    }

    before_each(function()
        fm.reset()
    end)

    it("merge_due: invalid FM dates emit a DateError and stay undated (strict)", function()
        for _, ds in ipairs(invalid) do
            fm.reset()
            local p = write_file("---\ndue: \"" .. ds .. "\"\ntags:\n  - work\n---\n")
            local tasks = { task(p, "undated", { line = 5 }) }
            local errs = {}
            fm.merge_due(tasks, {}, "%Y-%m-%d", errs)
            assert.is_nil(tasks[1].due_date, "date should stay nil: " .. ds)
            assert.are.equal(1, #errs, "one error for: " .. ds)
            assert.are.equal("frontmatter due", errs[1].context)
            assert.are.equal(p, errs[1].file_path)
        end
    end)

    it("merge_due: invalid FM dates are silently skipped (non-strict)", function()
        for _, ds in ipairs(invalid) do
            fm.reset()
            local p = write_file("---\ndue: \"" .. ds .. "\"\ntags:\n  - work\n---\n")
            local tasks = { task(p, "undated", { line = 5 }) }
            fm.merge_due(tasks, {}, "%Y-%m-%d", nil) -- nil collector
            assert.is_nil(tasks[1].due_date, "date should stay nil: " .. ds)
        end
    end)

    it("merge_due: valid FM dates set due_date with no errors", function()
        for _, ds in ipairs(valid) do
            fm.reset()
            local p = write_file("---\ndue: \"" .. ds .. "\"\n---\n")
            local tasks = { task(p, "t", { line = 5 }) }
            local errs = {}
            fm.merge_due(tasks, {}, "%Y-%m-%d", errs)
            assert.is_not_nil(tasks[1].due_date, "date should be set: " .. ds)
            assert.are.equal(0, #errs, "no errors for: " .. ds)
        end
    end)

    it("project_task: invalid project due emits a DateError and yields nil (strict)", function()
        for _, ds in ipairs(invalid) do
            fm.reset()
            local p = write_file("---\ndue: \"" .. ds .. "\"\ntags:\n  - project\n---\n- project\n")
            local errs = {}
            local t = fm.project_task(p, {}, "%Y-%m-%d", errs)
            assert.is_nil(t, "no project for invalid date: " .. ds)
            assert.are.equal(1, #errs, "one error for: " .. ds)
            assert.are.equal("frontmatter project due", errs[1].context)
        end
    end)

    it("project_task: invalid project due is silently skipped (non-strict)", function()
        for _, ds in ipairs(invalid) do
            fm.reset()
            local p = write_file("---\ndue: \"" .. ds .. "\"\ntags:\n  - project\n---\n- project\n")
            assert.is_nil(fm.project_task(p, {}, "%Y-%m-%d", nil))
        end
    end)
end)

-- =============================================================================
-- Edge / malformed (frontmatter-edge-vault, integration_test.go)
-- =============================================================================

describe("edge cases", function()
    before_each(function()
        fm.reset()
    end)

    it("empty frontmatter yields nil (no tags, no due)", function()
        local p = write_file("---\n---\n- [ ] Task with empty frontmatter\n")
        assert.is_nil(fm.parse_frontmatter(p))
        assert.are.same({}, fm.tags(p))
    end)

    it("malformed YAML does not crash and yields no tags", function()
        local p = write_file("---\ntags: [valid, yaml\nthis is broken yaml\n---\n- [ ] Task\n")
        -- broken `[valid, yaml` is not a closed flow list -> stored as a scalar
        -- string -> not a tag list. No crash; merge_tags is a no-op.
        assert.are.same({}, fm.tags(p))
        local tasks = { task(p, "t", { tags = { "inline" } }) }
        fm.merge_tags(tasks)
        assert.are.same({ "inline" }, tasks[1].tags)
    end)

    it("missing file: parse_frontmatter returns nil, ops are no-ops", function()
        local p = vim.fn.tempname() .. ".md" -- never created
        assert.is_nil(fm.parse_frontmatter(p))
        local tasks = { task(p, "t") }
        fm.merge_tags(tasks)
        tasks = fm.filter_completed(tasks, {})
        fm.merge_due(tasks, {}, "%Y-%m-%d", nil)
        assert.are.equal(1, #tasks)
        assert.is_nil(tasks[1].due_date)
    end)
end)
