local list = require("taskbuffer.list")
local config = require("taskbuffer.config")
local index = require("taskbuffer.index")
local parse = require("taskbuffer.parse")
local dir, saved, originals

local function wait_list(opts)
    local done, result, failure = false, nil, nil
    list.list_async(opts, function(text, err)
        done, result, failure = true, text, err
    end)
    assert.is_true(vim.wait(5000, function()
        return done
    end, 5))
    return result, failure
end

local function write(name, lines)
    vim.fn.writefile(lines, dir .. "/" .. name)
end

describe("async listing and source snapshots", function()
    before_each(function()
        saved = config.values
        originals = { parse = parse.parse_task, system = vim.system }
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        -- The scanner resolves aliases, including macOS /var -> /private/var.
        dir = assert(vim.uv.fs_realpath(dir))
        config.apply({ sources = { dir }, tmpdir = dir, state_dir = dir, inbox = { file = dir .. "/inbox.md" } })
        list.invalidate()
    end)
    after_each(function()
        config.values = saved
        parse.parse_task, vim.system = originals.parse, originals.system
        list.invalidate()
        vim.fn.delete(dir, "rf")
    end)

    it("should not spawn any process when listing, tagging, or sweeping", function()
        write("a.md", { "- [ ] One #work (@[[2026-09-11]])" })
        vim.system = function()
            error("no subprocess allowed")
        end
        local jobstart = vim.fn.jobstart
        vim.fn.jobstart = function()
            error("no subprocess allowed")
        end
        local ok, err = pcall(function()
            assert.is_truthy(list.list():find("One", 1, true))
            assert.are.same({ "work" }, list.tags())
            assert.is_truthy(wait_list():find("One", 1, true))
        end)
        vim.fn.jobstart = jobstart
        assert.is_true(ok, err)
    end)

    it("keeps native row metadata separate from cached script output and filtered views", function()
        write("a.md", { "- [ ] Same task #work", "- [ ] Other task #home" })
        local function view(opts)
            local done, result, failure = false
            list.view_async(opts or {}, function(value, err)
                result, failure, done = value, err, true
            end)
            assert.is_true(vim.wait(3000, function()
                return done
            end, 5))
            assert.is_nil(failure)
            return result
        end
        local first = view()
        assert.are.equal(dir .. "/a.md", first.rows[2].file_path)
        assert.are.equal(1, first.rows[2].line_number)
        assert.is_nil(table.concat(first.lines):find(dir, 1, true))
        local script = wait_list({ reuse = true })
        assert.is_truthy(script:find(dir .. "/a.md:1:1:", 1, true))
        local filtered = view({ reuse = true, tags = { "home" } })
        assert.are.equal(2, filtered.rows[2].line_number)
        assert.are.equal(1, first.rows[2].line_number)
        assert.is_nil(filtered.rows[3])
    end)

    it("preserves sync output for frontmatter, horizons, markers, filters, and strict errors", function()
        write("project.md", {
            "---",
            "tags:",
            "  - project",
            "  - work",
            "due: 2026-09-11",
            "---",
            "- [ ] Inherited task #inline",
            "- [x] Completed",
            "- [ ] Dated (@[[2026-09-12]] 10:00) ::start [[2026-09-11]] 09:00",
        })
        write("done.md", { "---", "due: 2026-09-11", "status: done", "---", "- [ ] Filtered task #kept-in-tags" })
        write("plain.md", { "- [ ] Undated #personal", "- [ ] Earlier (@[[2026-09-10]])" })
        for _, opts in ipairs({ {}, { markers = true }, { ignore_undated = true }, { tags = { "work" } } }) do
            local expected, err = list.list(opts)
            assert.is_nil(err)
            local actual, failure = wait_list(opts)
            assert.is_nil(failure)
            assert.are.equal(expected, actual)
        end
        local expected_tags = list.tags()
        local done = false
        list.tags_async({}, function(tags, err)
            assert.is_nil(err)
            assert.are.same(expected_tags, tags)
            done = true
        end)
        assert.is_true(vim.wait(1000, function()
            return done
        end, 5))
        config.values.strict = true
        write("bad.md", { "- [ ] Invalid (@[[2026-13-40]])" })
        local _, expected_error = list.list()
        local value, actual_error = wait_list()
        assert.is_nil(value)
        assert.are.equal(expected_error, actual_error)
    end)

    it("should reparse only changed files and skip discovery for view changes and tag queries", function()
        write("tasks.md", { "- [ ] One #work (@[[2026-09-11]])", "- [ ] Two #personal" })
        write("other.md", { "- [ ] Other" })
        local count = 0
        parse.parse_task = function(...)
            count = count + 1
            return originals.parse(...)
        end
        local initial = wait_list()
        assert.are.equal(3, count)
        assert.are.equal(initial, wait_list())
        assert.are.equal(3, count)
        vim.system = function()
            error("unnecessary scan")
        end
        local filtered, err = wait_list({ tags = { "work" }, reuse = true })
        assert.is_nil(err)
        assert.is_truthy(filtered:find("One", 1, true))
        assert.is_nil(filtered:find("Two", 1, true))
        local done = false
        list.tags_async({}, function(tags, failure)
            assert.is_nil(failure)
            assert.are.same({ "personal", "work" }, tags)
            done = true
        end)
        assert.is_true(vim.wait(1000, function()
            return done
        end, 5))
        assert.are.equal(3, count)
        -- Touch one file with a distinguishable size: only it is reparsed.
        write("other.md", { "- [ ] Other changed" })
        assert.is_truthy(wait_list():find("Other changed", 1, true))
        assert.are.equal(4, count)
    end)

    it("discovers source edits, additions, deletions, and frontmatter-only changes", function()
        write("tasks.md", { "---", "due: 2026-09-11", "---", "- [ ] Original" })
        assert.is_truthy(wait_list():find("Original", 1, true))
        write("tasks.md", { "---", "due: 2026-09-12", "tags:", "  - new-tag", "---", "- [ ] Original" })
        local changed = wait_list()
        assert.is_truthy(changed:find("2026-09-12", 1, true))
        assert.is_truthy(changed:find("#new-tag", 1, true))
        write("added.md", { "- [ ] Newly added" })
        assert.is_truthy(wait_list():find("Newly added", 1, true))
        vim.fn.delete(dir .. "/tasks.md")
        assert.is_nil(wait_list():find("Original", 1, true))
    end)

    it("should propagate a discovery error and suppress callbacks after cancellation", function()
        config.apply({ sources = { dir .. "/missing" }, tmpdir = dir, state_dir = dir })
        index.reset()
        local calls, failure = 0, nil
        list.list_async({}, function(_, err)
            calls = calls + 1
            failure = err
        end)
        assert.is_true(vim.wait(2000, function()
            return calls > 0
        end, 5))
        assert.is_truthy(failure:find("source not found", 1, true))
        local cancel = list.list_async({}, function()
            calls = calls + 1
        end)
        cancel()
        vim.wait(30, function()
            return false
        end, 5)
        assert.are.equal(1, calls)
    end)
end)
