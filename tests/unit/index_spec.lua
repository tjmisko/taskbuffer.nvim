local config = require("taskbuffer.config")
local index = require("taskbuffer.index")
local list = require("taskbuffer.list")
local parse = require("taskbuffer.parse")
local context = require("taskbuffer.context")
local golden = dofile(vim.fn.getcwd() .. "/tests/fixtures/golden/index_parity.lua")

local root = vim.fn.getcwd()
local now = os.time({ year = 2026, month = 2, day = 17, hour = 12 })
local dir, saved

local function write(name, lines)
    local path = dir .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
    return path
end

local function apply(extra)
    config.apply(vim.tbl_extend("force", {
        sources = { dir },
        tmpdir = dir,
        state_dir = dir,
        inbox = { file = dir .. "/inbox.md" },
    }, extra or {}))
    index.reset()
end

local function view(opts)
    local done, result, failure = false, nil, nil
    list.view_async(vim.tbl_extend("force", { now = now }, opts or {}), function(value, err)
        result, failure, done = value, err, true
    end)
    assert.is_true(vim.wait(5000, function()
        return done
    end, 5))
    assert.is_nil(failure)
    return table.concat(result.lines, "\n")
end

local function bump_mtime(path)
    -- Same-second rewrites can keep size and mtime; version also hashes ctime/ino
    -- but force a distinct mtime to keep the test independent of that.
    local stamp = os.time() + 60 + math.random(1, 1000)
    vim.uv.fs_utime(path, stamp, stamp)
end

describe("index build parity with the rg-based pipeline", function()
    local vaults = vim.fn.readdir(root .. "/tests/fixtures/vaults")
    for _, vault in ipairs(vaults) do
        for name, opts in pairs({
            default = {},
            markers = { markers = true },
            no_undated = { ignore_undated = true },
        }) do
            it("should render the same view when building " .. vault .. " with " .. name, function()
                local copy = vim.fn.tempname()
                vim.fn.mkdir(copy, "p")
                vim.fn.system({ "cp", "-a", root .. "/tests/fixtures/vaults/" .. vault .. "/.", copy })
                copy = assert(vim.uv.fs_realpath(copy))
                local previous = config.values
                dir = copy
                apply()
                local ok, err = pcall(function()
                    assert.are.equal(golden[vault][name], view(opts))
                    assert.are.same(golden[vault].tags, list.tags({ now = now }))
                end)
                config.values = previous
                index.reset()
                vim.fn.delete(copy, "rf")
                assert(ok, err)
            end)
        end
    end
end)

describe("index maintenance", function()
    before_each(function()
        saved = config.values
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        dir = assert(vim.uv.fs_realpath(dir))
        apply()
    end)
    after_each(function()
        config.values = saved
        index.reset()
        vim.fn.delete(dir, "rf")
    end)

    local function refresh()
        local data, err = index.refresh_sync(context.build_context(config.values, { now = now }))
        assert.is_nil(err)
        return data
    end

    it("should reparse only that file when update_file receives new contents", function()
        local a = write("a.md", { "- [ ] Alpha" })
        write("b.md", { "- [ ] Beta" })
        refresh()
        local count = 0
        local original = parse.parse_task
        parse.parse_task = function(...)
            count = count + 1
            return original(...)
        end
        local ok, err = pcall(function()
            assert.is_true(index.update_file(a, "- [ ] Alpha edited\n- [ ] Gamma\n"))
        end)
        parse.parse_task = original
        assert.is_true(ok, err)
        assert.are.equal(2, count)
        local bodies = {}
        for _, task in ipairs(index.current().tasks) do
            bodies[#bodies + 1] = task.body
        end
        assert.are.same({ "Alpha edited", "Gamma", "Beta" }, bodies)
    end)

    it("should drop a file when update_file receives nil contents", function()
        local a = write("a.md", { "- [ ] Alpha" })
        refresh()
        index.update_file(a, nil)
        assert.are.equal(0, #index.current().tasks)
    end)

    it("should report false when update_file runs before any index exists", function()
        assert.is_false(index.update_file(dir .. "/a.md", "- [ ] x\n"))
    end)

    it("should pick up modified, new, and deleted files when sweeping", function()
        local a = write("a.md", { "- [ ] Alpha" })
        write("gone.md", { "- [ ] Doomed" })
        local before = refresh()
        assert.are.equal(2, #before.tasks)
        write("a.md", { "- [ ] Alpha changed", "- [ ] Alpha second" })
        bump_mtime(a)
        write("new.md", { "- [ ] Fresh" })
        vim.fn.delete(dir .. "/gone.md")
        local after = refresh()
        local bodies = {}
        for _, task in ipairs(after.tasks) do
            bodies[#bodies + 1] = task.body
        end
        table.sort(bodies)
        assert.are.same({ "Alpha changed", "Alpha second", "Fresh" }, bodies)
        assert.are_not.equal(before.revision, after.revision)
    end)

    it("should keep the same snapshot object when a sweep finds nothing changed", function()
        write("a.md", { "- [ ] Alpha" })
        local first = refresh()
        assert.are.equal(first, refresh())
    end)

    it("should merge frontmatter tags, due, and status from in-memory data", function()
        local ctx = context.build_context(config.values, { now = now })
        local data = table.concat({
            "---",
            "tags:",
            "  - project",
            "  - work",
            "due: 2026-09-11",
            "---",
            "- [ ] Inherited #inline",
            "- [x] Done already",
            "- [ ] Dated (@[[2026-09-12]])",
        }, "\n")
        local entry = index.parse_file("/x/project.md", data, ctx, "v1")
        assert.are.equal(3, #entry.tasks)
        assert.are.same({ "inline", "project", "work" }, entry.tasks[1].tags)
        assert.are.equal("2026-09-11", os.date("%Y-%m-%d", entry.tasks[1].due_date))
        assert.are.equal("2026-09-12", os.date("%Y-%m-%d", entry.tasks[3].due_date))
        assert.is_not_nil(entry.project)
        assert.are.equal("project", entry.project.body)
        assert.is_true(entry.project.sort_last)
        local done =
            index.parse_file("/x/done.md", "---\ndue: 2026-09-11\nstatus: done\n---\n- [ ] Filtered #kept\n", ctx, "v1")
        assert.are.equal(0, #done.tasks)
        assert.are.equal(1, #done.all)
    end)

    it("should not read the disk when parse_file gets frontmatter data", function()
        local ctx = context.build_context(config.values, { now = now })
        local open = io.open
        io.open = function()
            error("parse_file must not reopen the file")
        end
        local ok, err = pcall(index.parse_file, "/does/not/exist.md", "---\ntags:\n  - a\n---\n- [ ] T\n", ctx, "v")
        io.open = open
        assert.is_true(ok, err)
    end)

    it("should record original text and strip carriage returns when files use CRLF", function()
        local ctx = context.build_context(config.values, { now = now })
        local entry = index.parse_file("/x/crlf.md", "- [ ] One\r\n  - [ ] Two (@[[2026-02-17]])\r\n", ctx, "v")
        assert.are.equal(2, #entry.tasks)
        assert.are.equal("- [ ] One", entry.originals[1])
        assert.are.equal("  - [ ] Two (@[[2026-02-17]])", entry.originals[2])
        assert.are.equal("Two", entry.tasks[2].body)
    end)

    it("should handle empty files, a missing trailing newline, and blank lines", function()
        local ctx = context.build_context(config.values, { now = now })
        assert.are.equal(0, #index.parse_file("/x/e.md", "", ctx, "v").tasks)
        assert.are.equal(0, #index.parse_file("/x/e.md", "\n\n   \n", ctx, "v").tasks)
        local entry = index.parse_file("/x/e.md", "\n- [ ] last line no newline", ctx, "v")
        assert.are.equal(1, #entry.tasks)
        assert.are.equal(2, entry.tasks[1].line_number)
    end)

    it("should ignore lines that only contain a checkbox mid-line", function()
        local ctx = context.build_context(config.values, { now = now })
        assert.are.equal(0, #index.parse_file("/x/e.md", "see - [ ] not a task\n", ctx, "v").tasks)
    end)

    it("should honor custom checkbox literals when finding task lines", function()
        apply({ formats = { checkbox = { open = "TODO:", done = "DONE:" } } })
        local ctx = context.build_context(config.values, { now = now })
        local entry = index.parse_file("/x/e.md", "TODO: custom\n- [ ] default\nDONE: finished\n", ctx, "v")
        assert.are.equal(2, #entry.all)
        assert.are.equal("custom", entry.all[1].body)
    end)

    it("should read annotation files by pattern without using the search regex", function()
        local rule = { extension = "rs", pattern = '^%s*todo!%s*%(%s*"(.-)"%s*%)%s*;?%s*$' }
        apply({ annotations = { rule } })
        local ctx = context.build_context(config.values, { now = now })
        local entry = index.parse_file("/x/lib.rs", 'fn a() {}\n    todo!("Do it #code");\n', ctx, "v")
        assert.are.equal(1, #entry.tasks)
        assert.is_true(entry.annotations[2])
        assert.are.equal("Do it", entry.tasks[1].body)
        -- A rule that still carries the legacy search key keeps working.
        rule.search = "todo!"
        apply({ annotations = { rule } })
        assert.is_not_nil(context.build_context(config.values, {}))
    end)

    it("should treat binary markdown as having no tasks when it contains NUL", function()
        local ctx = context.build_context(config.values, { now = now })
        assert.are.equal(0, #index.parse_file("/x/b.md", "- [ ] Task\0\n", ctx, "v").tasks)
    end)

    it("should collect strict-mode date errors per file and surface them in the snapshot", function()
        apply({ strict = true })
        write("bad.md", { "- [ ] Invalid (@[[2026-13-40]])" })
        write("good.md", { "- [ ] Fine (@[[2026-02-17]])" })
        local data = refresh()
        assert.are.equal(1, #data.errors)
        local _, err = list.list({ now = now })
        assert.is_truthy(err)
        assert.are.same({}, list.tags({ now = now }))
    end)

    it("should rebuild when the configuration changes", function()
        write("a.md", { "- [ ] Alpha" })
        refresh()
        assert.is_true(index.is_ready())
        config.values.strict = true
        local data = refresh()
        assert.are.same({}, data.errors)
    end)

    it("should use the excluded directories from config", function()
        write("keep/a.md", { "- [ ] Keep" })
        write("node_modules/x.md", { "- [ ] Skip" })
        write(".hidden/y.md", { "- [ ] Hidden" })
        assert.are.equal(1, #refresh().tasks)
        apply({ exclude = {} })
        assert.are.equal(2, #refresh().tasks)
    end)

    it("should return an error from refresh when a source disappears", function()
        local ctx = context.build_context(config.values, { now = now })
        vim.fn.delete(dir, "rf")
        local data, err = index.refresh_sync(ctx)
        assert.is_nil(data)
        assert.is_truthy(err)
    end)

    it("should abort an async refresh when the index is reset during it", function()
        for i = 1, 40 do
            write("n" .. i .. ".md", { "- [ ] Task " .. i })
        end
        local ctx = context.build_context(config.values, { now = now })
        local err, done
        index.refresh_async(ctx, function(_, failure)
            err, done = failure, true
        end)
        index.reset()
        assert.is_true(vim.wait(5000, function()
            return done
        end, 5))
        assert.are.equal(index.RESET_ERROR, err)
    end)

    it("should return the edited content when a sweep is cancelled after reparsing a changed file", function()
        for i = 1, 3000 do
            write(string.format("n%04d.md", i), { "- [ ] Task " .. i })
        end
        local ctx = context.build_context(config.values, { now = now })
        local before = index.refresh_sync(ctx)
        assert.is_truthy(before)
        local edited = write("n0001.md", { "- [ ] Edited one" })
        bump_mtime(edited)
        local cancel = index.refresh_async(ctx, function() end)
        local reparsed = vim.wait(5000, function()
            local entry = index.entry(edited)
            return entry and entry.all[1] and entry.all[1].body:find("Edited", 1, true) ~= nil
        end, 1)
        cancel()
        assert.is_true(reparsed)
        local after = index.refresh_sync(ctx)
        assert.are_not.equal(before, after)
        assert.are.equal("Edited one", index.entry(edited).all[1].body)
    end)

    it("should accept paths below a source and reject hidden, excluded, and outside paths", function()
        write("a.md", { "- [ ] Alpha" })
        refresh()
        assert.is_true(index.accepts(dir .. "/a.md"))
        assert.is_true(index.accepts(dir .. "/new/created-later.md"))
        assert.is_false(index.accepts(dir .. "/.hidden/x.md"))
        assert.is_false(index.accepts(dir .. "/node_modules/x.md"))
        assert.is_false(index.accepts(dir .. "/notes.txt"))
        assert.is_false(index.accepts("/somewhere/else.md"))
    end)

    it("should reparse a note when it is written through BufWritePost", function()
        require("taskbuffer.autocmds").register()
        local path = write("a.md", { "- [ ] Before" })
        refresh()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "- [ ] After", "- [ ] Added" })
        vim.cmd("write")
        local bodies = {}
        for _, task in ipairs(index.current().tasks) do
            bodies[#bodies + 1] = task.body
        end
        vim.cmd("bwipeout!")
        assert.are.same({ "After", "Added" }, bodies)
    end)

    it("should ignore BufWritePost for files outside the sources", function()
        require("taskbuffer.autocmds").register()
        write("a.md", { "- [ ] Alpha" })
        refresh()
        local revision = index.revision()
        local outside = vim.fn.tempname() .. ".md"
        vim.cmd("edit " .. vim.fn.fnameescape(outside))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "- [ ] Elsewhere" })
        vim.cmd("write")
        vim.cmd("bwipeout!")
        vim.fn.delete(outside)
        assert.are.equal(revision, index.revision())
    end)
end)
