local format = require("taskbuffer.format")
local noon = require("taskbuffer.strftime").date_to_epoch(2026, 9, 11)

local function task(path, row, fields)
    return vim.tbl_extend("force", {
        file_path = path,
        line_number = row,
        body = "Same task",
        status = "open",
        tags = {},
        markers = {},
        due_time = "",
        duration = "",
    }, fields or {})
end

describe("visible task rows", function()
    it("keeps identical-looking tasks distinct without putting locations in text", function()
        local a, b = task("/work/a.md", 2), task("/personal/b.md", 5)
        local view = format.format_view({ a, b }, noon)
        assert.are.same(
            { "# Someday", "           |       |      | Same task", "           |       |      | Same task" },
            view.lines
        )
        assert.is_nil(view.rows[1])
        assert.are.equal(b, view.rows[2]) -- sorted by source path
        assert.are.equal(a, view.rows[3])
        assert.is_nil(table.concat(view.lines):find(".md", 1, true))
        assert.is_nil(table.concat(view.lines):find("\t", 1, true))
    end)

    it("keeps headers, blank lines, filters and task associations in sync", function()
        local a = task("/work/a.md", 2, { due_date = noon, tags = { "work" } })
        local b = task("/home/b.md", 1, { tags = { "home" } })
        local c = task("/work/c.md", 8, { tags = { "work" } })
        local view = format.format_view({ c, b, a }, noon, { tag_filter = { "work" } })
        assert.are.equal("# Today", view.lines[1])
        assert.are.equal(a, view.rows[2])
        assert.are.equal("", view.lines[3])
        assert.are.equal("# Someday", view.lines[4])
        assert.are.equal(c, view.rows[5])
        assert.is_nil(view.rows[3])
        assert.is_nil(view.rows[4])
        local dated = format.format_view({ a, b, c }, noon, { ignore_undated = true })
        assert.are.equal(2, #dated.lines)
        assert.are.equal(a, dated.rows[2])
        assert.are.same({ lines = {}, rows = {} }, format.format_view({}, noon))
    end)

    it("renders searchable dates, tags, Unicode and optional markers without conceal syntax", function()
        local t = task("/code/main.rs", 3, {
            body = "Implement 界",
            due_date = noon,
            due_time = "14:30",
            duration = "15m",
            tags = { "code" },
            markers = { { kind = "start", date = "2026-09-11", time = "14:00" } },
        })
        assert.are.equal(
            "11/09/2026 | 14:30 |  15m | Implement 界 #code ::start [[2026-09-11]] 14:00",
            format.format_task_text(t, { date_strftime = "%d/%m/%Y", markers = true })
        )
        assert.is_nil(format.format_task_text(t):find("::start", 1, true))
        assert.is_truthy(format.format_task_line(t, {}):find("/code/main.rs:3:1:", 1, true))
    end)
end)
