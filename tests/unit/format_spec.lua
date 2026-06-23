-- Ported from go/format_test.go.
-- The line-format tests are BYTE-EXACT equality assertions (the want strings
-- encode the tab/space column layout). The bucketing tests use string.find
-- offsets to assert relative section/task positions, mirroring strings.Index.

local format = require("taskbuffer.format")
local strftime = require("taskbuffer.strftime")

-- Fixed "now": 2026-02-17 (a Tuesday), matching Go's testNow.
local NOW = strftime.date_to_epoch(2026, 2, 17)

local DEFAULT_OPTS = {}
local MARKERS_OPTS = { markers = true }

local function epoch(y, m, d)
    return strftime.date_to_epoch(y, m, d)
end

-- Plain-text index (1-based) or nil; mirrors strings.Index semantics for tests.
local function at(s, sub)
    return (s:find(sub, 1, true))
end

-- Build a canonical Task table. Pass y=nil for an undated task.
local function mk(file_path, line_number, body, y, m, d, extra)
    local t = {
        file_path = file_path,
        line_number = line_number,
        body = body,
        due_time = "",
        duration = "",
    }
    if y then
        t.due_date = epoch(y, m, d)
    end
    if extra then
        for k, v in pairs(extra) do
            t[k] = v
        end
    end
    return t
end

describe("format.format_task_line — byte-exact column layout", function()
    it("simple dated task", function()
        local task = mk("/notes/project.md", 11, "Buy groceries", 2026, 2, 17)
        local want = "/notes/project.md:11:1:\t[[2026-02-17]]\t |       |     |\t Buy groceries \t"
        assert.are.equal(want, format.format_task_line(task, DEFAULT_OPTS))
    end)

    it("with time", function()
        local task = mk("/notes/test.md", 5, "Team meeting", 2026, 2, 17, { due_time = "16:00" })
        local want = "/notes/test.md:5:1:\t[[2026-02-17]] | 16:00 |     |\t Team meeting \t"
        assert.are.equal(want, format.format_task_line(task, DEFAULT_OPTS))
    end)

    it("with duration (90m, no time -> leading tab)", function()
        local task = mk("/notes/test.md", 1, "Deep work", 2026, 2, 17, { duration = "90m" })
        local want = "/notes/test.md:1:1:\t[[2026-02-17]]\t |       | 90m |\t Deep work \t"
        assert.are.equal(want, format.format_task_line(task, DEFAULT_OPTS))
    end)

    it("with tags", function()
        local task = mk("/notes/test.md", 1, "Run 5k", 2026, 2, 17, { tags = { "exercise", "target" } })
        local want = "/notes/test.md:1:1:\t[[2026-02-17]]\t |       |     |\t Run 5k \t #exercise #target"
        assert.are.equal(want, format.format_task_line(task, DEFAULT_OPTS))
    end)

    it("with markers (shown)", function()
        local task = mk("/notes/test.md", 1, "Some task", 2026, 1, 21, {
            markers = {
                { kind = "original", date = "2026-01-14" },
                { kind = "deferral", date = "2026-01-21", time = "12:03" },
            },
        })
        local want = "/notes/test.md:1:1:\t[[2026-01-21]]\t |       |     |\t Some task \t"
            .. " ::original [[2026-01-14]] ::deferral [[2026-01-21]] 12:03"
        assert.are.equal(want, format.format_task_line(task, MARKERS_OPTS))
    end)

    it("hides markers by default", function()
        local task = mk("/notes/test.md", 1, "Some task", 2026, 1, 21, {
            markers = { { kind = "original", date = "2026-01-14" } },
        })
        local got = format.format_task_line(task, DEFAULT_OPTS)
        assert.is_nil(at(got, "::original"))
    end)

    it("full task (time + duration + markers)", function()
        local task = mk("/notes/project.md", 42, "Rewrite About Me Section", 2026, 1, 23, {
            due_time = "15:00",
            duration = "30m",
            markers = {
                { kind = "start", date = "2026-01-23", time = "15:17" },
                { kind = "complete", date = "2026-01-23", time = "17:19" },
            },
        })
        local want = "/notes/project.md:42:1:\t[[2026-01-23]] | 15:00 | 30m |\t Rewrite About Me Section \t"
            .. " ::start [[2026-01-23]] 15:17 ::complete [[2026-01-23]] 17:19"
        assert.are.equal(want, format.format_task_line(task, MARKERS_OPTS))
    end)

    it("short duration right-justifies to width 4", function()
        local task = mk("/notes/test.md", 1, "Quick task", 2026, 2, 17, { duration = "5m" })
        local want = "/notes/test.md:1:1:\t[[2026-02-17]]\t |       |  5m |\t Quick task \t"
        assert.are.equal(want, format.format_task_line(task, DEFAULT_OPTS))
    end)

    it("undated task uses 10 spaces for the date column", function()
        local task = mk("/notes/someday.md", 3, "Investigate OOM Kill", nil)
        local want = "/notes/someday.md:3:1:\t          \t |       |     |\t Investigate OOM Kill \t"
        assert.are.equal(want, format.format_task_line(task, DEFAULT_OPTS))
    end)
end)

describe("format.format_taskfile — buckets and headers", function()
    it("places tasks under the right default horizon headers", function()
        local tasks = {
            mk("/a.md", 1, "Overdue task", 2026, 2, 15),
            mk("/b.md", 2, "Today task", 2026, 2, 17),
            mk("/c.md", 3, "Tomorrow task", 2026, 2, 18),
            mk("/d.md", 4, "This week task", 2026, 2, 19),
            mk("/e.md", 5, "This month task", 2026, 2, 26),
            mk("/f.md", 6, "This year task", 2026, 4, 1),
            mk("/g.md", 7, "Far off task", 2028, 1, 1),
        }
        local got = format.format_taskfile(tasks, NOW, DEFAULT_OPTS)

        for _, header in ipairs({ "# Overdue", "# Today", "# Tomorrow", "# This Week", "# This Month", "# This Year", "# Far Off" }) do
            assert.is_not_nil(at(got, header), "missing header " .. header)
        end

        local overdue_idx = at(got, "# Overdue")
        local today_idx = at(got, "# Today")
        local tomorrow_idx = at(got, "# Tomorrow")
        local far_off_idx = at(got, "# Far Off")

        assert.is_true(at(got, "Overdue task") > overdue_idx and at(got, "Overdue task") < today_idx)
        assert.is_true(at(got, "Today task") > today_idx and at(got, "Today task") < tomorrow_idx)
        assert.is_true(at(got, "Tomorrow task") > tomorrow_idx)
        assert.is_true(at(got, "Far off task") > far_off_idx)
    end)

    it("sorts tasks by date", function()
        local tasks = {
            mk("/b.md", 1, "Later", 2026, 2, 19),
            mk("/a.md", 1, "Earlier", 2026, 2, 17),
        }
        local got = format.format_taskfile(tasks, NOW, DEFAULT_OPTS)
        assert.is_true(at(got, "Earlier") < at(got, "Later"))
    end)

    it("returns empty string for nil tasks", function()
        assert.are.equal("", format.format_taskfile(nil, NOW, DEFAULT_OPTS))
    end)

    it("skips empty buckets", function()
        local tasks = { mk("/a.md", 1, "Only today", 2026, 2, 17) }
        local got = format.format_taskfile(tasks, NOW, DEFAULT_OPTS)
        assert.is_nil(at(got, "# Overdue"))
        assert.is_not_nil(at(got, "# Today"))
        assert.is_nil(at(got, "# Tomorrow"))
    end)
end)

describe("format.format_taskfile — undated handling", function()
    it("places undated tasks under the Someday bucket after dated", function()
        local tasks = {
            mk("/a.md", 1, "Today task", 2026, 2, 17),
            mk("/b.md", 2, "Undated task one", nil),
            mk("/c.md", 3, "Undated task two", nil),
        }
        local got = format.format_taskfile(tasks, NOW, DEFAULT_OPTS)
        assert.is_not_nil(at(got, "# Today"))
        assert.is_not_nil(at(got, "# Someday"))
        assert.is_true(at(got, "# Someday") > at(got, "# Today"))
        assert.is_true(at(got, "Undated task one") > at(got, "# Someday"))
        assert.is_true(at(got, "Undated task two") > at(got, "# Someday"))
    end)

    it("shows only the Someday bucket when all tasks are undated", function()
        local tasks = { mk("/a.md", 1, "Undated only", nil) }
        local got = format.format_taskfile(tasks, NOW, DEFAULT_OPTS)
        assert.is_not_nil(at(got, "# Someday"))
        assert.is_nil(at(got, "# Today"))
    end)

    it("drops the undated section when ignore_undated is set", function()
        local tasks = {
            mk("/a.md", 1, "Today task", 2026, 2, 17),
            mk("/b.md", 2, "Undated task", nil),
        }
        local got = format.format_taskfile(tasks, NOW, { ignore_undated = true })
        assert.is_nil(at(got, "# Someday"))
        assert.is_nil(at(got, "Undated task"))
        assert.is_not_nil(at(got, "Today task"))
    end)

    it("keeps dated tasks when ignore_undated drops the undated ones", function()
        local tasks = {
            mk("/a.md", 1, "Overdue task", 2026, 2, 15),
            mk("/b.md", 2, "Today task", 2026, 2, 17),
            mk("/c.md", 3, "Undated task", nil),
        }
        local got = format.format_taskfile(tasks, NOW, { ignore_undated = true })
        assert.is_not_nil(at(got, "# Overdue"))
        assert.is_not_nil(at(got, "# Today"))
        assert.is_not_nil(at(got, "Overdue task"))
        assert.is_not_nil(at(got, "Today task"))
        assert.is_nil(at(got, "# Someday"))
        assert.is_nil(at(got, "Undated task"))
    end)
end)

describe("format.format_taskfile — tag filter", function()
    it("keeps only tasks with the filtered tag", function()
        local tasks = {
            mk("/a.md", 1, "Tagged task", 2026, 2, 17, { tags = { "sspi" } }),
            mk("/b.md", 2, "Untagged task", 2026, 2, 17),
            mk("/c.md", 3, "Other tagged", 2026, 2, 17, { tags = { "project" } }),
        }
        local got = format.format_taskfile(tasks, NOW, { tag_filter = { "sspi" } })
        assert.is_not_nil(at(got, "Tagged task"))
        assert.is_nil(at(got, "Untagged task"))
        assert.is_nil(at(got, "Other tagged"))
    end)

    it("matches any of multiple filter tags (OR logic)", function()
        local tasks = {
            mk("/a.md", 1, "SSPI task", 2026, 2, 17, { tags = { "sspi" } }),
            mk("/b.md", 2, "Project task", 2026, 2, 17, { tags = { "project" } }),
            mk("/c.md", 3, "Neither", 2026, 2, 17, { tags = { "other" } }),
        }
        local got = format.format_taskfile(tasks, NOW, { tag_filter = { "sspi", "project" } })
        assert.is_not_nil(at(got, "SSPI task"))
        assert.is_not_nil(at(got, "Project task"))
        assert.is_nil(at(got, "Neither"))
    end)
end)

-- ── Bucketing units (hand-built ResolvedHorizon lists; 1-based indices) ──

local function H(label, cutoff_days)
    return { label = label, cutoff = strftime.add_days(NOW, cutoff_days), undated = false }
end

describe("format.in_horizon — boundaries", function()
    local horizons = { H("# H0", 0), H("# H1", 2), H("# H2", 5) }
    local cases = {
        { name = "day0 in H0", days = 0, idx = 1, want = true },
        { name = "day0 in H1", days = 0, idx = 2, want = false },
        { name = "day1 in H0", days = 1, idx = 1, want = true },
        { name = "day2 in H0", days = 2, idx = 1, want = false },
        { name = "day2 in H1", days = 2, idx = 2, want = true },
        { name = "day5 in H2", days = 5, idx = 3, want = true },
        { name = "day10 in H2", days = 10, idx = 3, want = true },
        { name = "day5 in H1", days = 5, idx = 2, want = false },
    }
    for _, tc in ipairs(cases) do
        it(tc.name, function()
            assert.are.equal(tc.want, format.in_horizon(strftime.add_days(NOW, tc.days), tc.idx, horizons))
        end)
    end
end)

describe("format.first_match_horizon", function()
    -- Unsorted: Narrow(+3), Wide(+0), Far(+7).
    local horizons = { H("# Narrow", 3), H("# Wide", 0), H("# Far", 7) }
    it("day4 matches Narrow (idx 1) first", function()
        assert.are.equal(1, format.first_match_horizon(strftime.add_days(NOW, 4), horizons))
    end)
    it("day1 matches Wide (idx 2) first", function()
        assert.are.equal(2, format.first_match_horizon(strftime.add_days(NOW, 1), horizons))
    end)
    it("day8 matches Narrow (idx 1) first", function()
        assert.are.equal(1, format.first_match_horizon(strftime.add_days(NOW, 8), horizons))
    end)
    it("falls back to the last dated horizon when none match", function()
        local future = { H("# A", 10), H("# B", 20) }
        assert.are.equal(2, format.first_match_horizon(NOW, future))
    end)
end)

describe("format.narrowest_horizon", function()
    -- Wide(+0), Narrow(+2), Far(+5, open-ended last).
    local horizons = { H("# Wide", 0), H("# Narrow", 2), H("# Far", 5) }
    it("day3 lands in Narrow (idx 2), not Wide", function()
        assert.are.equal(2, format.narrowest_horizon(strftime.add_days(NOW, 3), horizons))
    end)
    it("day1 lands in Wide (idx 1)", function()
        assert.are.equal(1, format.narrowest_horizon(strftime.add_days(NOW, 1), horizons))
    end)
    it("day6 lands in the open-ended Far (idx 3)", function()
        assert.are.equal(3, format.narrowest_horizon(strftime.add_days(NOW, 6), horizons))
    end)
end)

describe("format.format_taskfile — custom horizons", function()
    it("uses provided horizons and custom undated label", function()
        local horizons = {
            { label = "# Urgent", cutoff = NOW, undated = false },
            { label = "# Soon", cutoff = strftime.add_days(NOW, 3), undated = false },
            { label = "# Later", cutoff = strftime.add_days(NOW, 10), undated = false },
            { label = "# Backlog", undated = true },
        }
        local tasks = {
            mk("/a.md", 1, "Fix crash", 2026, 2, 17),
            mk("/b.md", 2, "Write docs", 2026, 2, 22),
            mk("/c.md", 3, "Plan refactor", 2026, 3, 4),
            mk("/d.md", 4, "Someday idea", nil),
        }
        local got = format.format_taskfile(tasks, NOW, { horizons = horizons })

        for _, header in ipairs({ "# Urgent", "# Soon", "# Later", "# Backlog" }) do
            assert.is_not_nil(at(got, header), "missing header " .. header)
        end

        local urgent_idx = at(got, "# Urgent")
        local soon_idx = at(got, "# Soon")
        local later_idx = at(got, "# Later")
        local backlog_idx = at(got, "# Backlog")

        assert.is_true(at(got, "Fix crash") > urgent_idx and at(got, "Fix crash") < soon_idx)
        assert.is_true(at(got, "Write docs") > soon_idx and at(got, "Write docs") < later_idx)
        assert.is_true(at(got, "Plan refactor") > later_idx and at(got, "Plan refactor") < backlog_idx)
        assert.is_true(at(got, "Someday idea") > backlog_idx)
        assert.is_nil(at(got, "# Someday"))
    end)
end)

describe("format.format_taskfile — overlap strategies", function()
    it("first_match: list order decides the bucket", function()
        local horizons = {
            { label = "# Priority", cutoff = strftime.add_days(NOW, 2), undated = false },
            { label = "# General", cutoff = NOW, undated = false },
            { label = "# Someday", undated = true },
        }
        local tasks = {
            mk("/a.md", 1, "Priority task", 2026, 2, 20),
            mk("/b.md", 2, "General task", 2026, 2, 18),
        }
        local got = format.format_taskfile(tasks, NOW, { horizons = horizons, overlap = "first_match" })

        local priority_idx = at(got, "# Priority")
        local general_idx = at(got, "# General")
        assert.is_not_nil(priority_idx)
        assert.is_not_nil(general_idx)
        assert.is_true(at(got, "General task") > general_idx)
        assert.is_true(at(got, "Priority task") > priority_idx)
        -- General task (Feb 18) sorts before Priority task (Feb 20).
        assert.is_true(general_idx < priority_idx)
    end)

    it("narrowest: tightest containing range wins", function()
        local horizons = {
            { label = "# Wide", cutoff = NOW, undated = false },
            { label = "# Narrow", cutoff = strftime.add_days(NOW, 3), undated = false },
            { label = "# Far", cutoff = strftime.add_days(NOW, 7), undated = false },
            { label = "# Backlog", undated = true },
        }
        local tasks = {
            mk("/a.md", 1, "Wide task", 2026, 2, 18),
            mk("/b.md", 2, "Narrow task", 2026, 2, 21),
            mk("/c.md", 3, "Far task", 2026, 2, 25),
        }
        local got = format.format_taskfile(tasks, NOW, { horizons = horizons, overlap = "narrowest" })

        local wide_idx = at(got, "# Wide")
        local narrow_idx = at(got, "# Narrow")
        local far_idx = at(got, "# Far")
        assert.is_not_nil(wide_idx)
        assert.is_not_nil(narrow_idx)
        assert.is_not_nil(far_idx)
        assert.is_true(at(got, "Wide task") > wide_idx and at(got, "Wide task") < narrow_idx)
        assert.is_true(at(got, "Narrow task") > narrow_idx and at(got, "Narrow task") < far_idx)
        assert.is_true(at(got, "Far task") > far_idx)
    end)
end)

describe("format.format_taskfile — boundary and edge cases", function()
    it("exact cutoff date lands in the upper bucket; empty buckets skipped", function()
        local horizons = {
            { label = "# Past", cutoff = strftime.add_days(NOW, -5), undated = false },
            { label = "# Present", cutoff = NOW, undated = false },
            { label = "# Future", cutoff = strftime.add_days(NOW, 5), undated = false },
        }
        local tasks = {
            mk("/a.md", 1, "Present task", 2026, 2, 17),
            mk("/b.md", 2, "Future task", 2026, 2, 22),
        }
        local got = format.format_taskfile(tasks, NOW, { horizons = horizons })

        local present_idx = at(got, "# Present")
        local future_idx = at(got, "# Future")
        assert.is_not_nil(present_idx)
        assert.is_not_nil(future_idx)
        assert.is_true(at(got, "Present task") > present_idx and at(got, "Present task") < future_idx)
        assert.is_true(at(got, "Future task") > future_idx)
        assert.is_nil(at(got, "# Past"))
    end)

    it("single open-ended horizon catches every task", function()
        local horizons = {
            { label = "# Everything", cutoff = strftime.add_days(NOW, -100), undated = false },
        }
        local tasks = {
            mk("/a.md", 1, "Old task", 2026, 1, 1),
            mk("/b.md", 2, "Today task", 2026, 2, 17),
            mk("/c.md", 3, "Future task", 2026, 6, 1),
        }
        local got = format.format_taskfile(tasks, NOW, { horizons = horizons })

        local header_idx = at(got, "# Everything")
        assert.is_not_nil(header_idx)
        for _, body in ipairs({ "Old task", "Today task", "Future task" }) do
            assert.is_not_nil(at(got, body), "missing task " .. body)
            assert.is_true(at(got, body) > header_idx)
        end
    end)

    it("same-date tasks sort by file path", function()
        local horizons = {
            { label = "# Today", cutoff = NOW, undated = false },
            { label = "# Future", cutoff = strftime.add_days(NOW, 7), undated = false },
        }
        local tasks = {
            mk("/c.md", 1, "Task C", 2026, 2, 17),
            mk("/a.md", 1, "Task A", 2026, 2, 17),
            mk("/b.md", 1, "Task B", 2026, 2, 17),
        }
        local got = format.format_taskfile(tasks, NOW, { horizons = horizons })

        assert.is_not_nil(at(got, "# Today"))
        assert.is_nil(at(got, "# Future"))
        assert.is_true(at(got, "Task A") < at(got, "Task B"))
        assert.is_true(at(got, "Task B") < at(got, "Task C"))
    end)

    it("uses the custom undated label, not the default", function()
        local horizons = {
            { label = "# Tasks", cutoff = NOW, undated = false },
            { label = "# Inbox", undated = true },
        }
        local tasks = { mk("/a.md", 1, "Undated thing", nil) }
        local got = format.format_taskfile(tasks, NOW, { horizons = horizons })
        assert.is_not_nil(at(got, "# Inbox"))
        assert.is_nil(at(got, "# Someday"))
        assert.is_not_nil(at(got, "Undated thing"))
    end)
end)

describe("format — sort_last ordering", function()
    it("places sort_last tasks after regular tasks at the same key", function()
        local horizons = { { label = "# Today", cutoff = NOW, undated = false } }
        local tasks = {
            mk("/a.md", 5, "Project synthetic", 2026, 2, 17, { sort_last = true }),
            mk("/a.md", 5, "Real task", 2026, 2, 17),
        }
        local got = format.format_taskfile(tasks, NOW, { horizons = horizons })
        assert.is_true(at(got, "Real task") < at(got, "Project synthetic"))
    end)
end)
