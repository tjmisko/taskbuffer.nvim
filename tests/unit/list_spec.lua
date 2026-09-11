local list = require("taskbuffer.list")
local config = require("taskbuffer.config")
local scan = require("taskbuffer.scan")
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
        originals = {
            scan = scan.scan,
            projects = scan.scan_project_paths,
            scan_async = scan.scan_async,
            projects_async = scan.scan_project_paths_async,
            parse = parse.parse_tasks,
            system = vim.system,
        }
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        config.apply({ sources = { dir }, tmpdir = dir, state_dir = dir, inbox = { file = dir .. "/inbox.md" } })
        list.invalidate()
    end)
    after_each(function()
        config.values = saved
        scan.scan, scan.scan_project_paths = originals.scan, originals.projects
        scan.scan_async, scan.scan_project_paths_async = originals.scan_async, originals.projects_async
        parse.parse_tasks, vim.system = originals.parse, originals.system
        list.invalidate()
        vim.fn.delete(dir, "rf")
    end)

    it("runs both discovery scans concurrently without synchronous fallback", function()
        local tasks_cb, projects_cb
        scan.scan = function()
            error("sync scan")
        end
        scan.scan_project_paths = function()
            error("sync project scan")
        end
        scan.scan_async = function(_, cb)
            tasks_cb = cb
            return function() end
        end
        scan.scan_project_paths_async = function(_, cb)
            projects_cb = cb
            return function() end
        end
        local done = false
        list.list_async({}, function(_, err)
            assert.is_nil(err)
            done = true
        end)
        assert.is_function(tasks_cb)
        assert.is_function(projects_cb)
        assert.is_false(done)
        tasks_cb({}, nil)
        assert.is_false(done)
        projects_cb({}, nil)
        assert.is_true(vim.wait(1000, function()
            return done
        end, 5))
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

    it("skips unchanged parsing and skips discovery for view changes/tag queries", function()
        write("tasks.md", { "- [ ] One #work (@[[2026-09-11]])", "- [ ] Two #personal" })
        local count = 0
        parse.parse_tasks = function(...)
            count = count + 1
            return originals.parse(...)
        end
        local initial = wait_list()
        assert.are.equal(initial, wait_list())
        assert.are.equal(1, count)
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
        assert.are.equal(1, count)
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

    it("propagates project scan errors and suppresses callbacks after cancellation", function()
        local tasks_cb, projects_cb
        local killed = 0
        scan.scan_async = function(_, cb)
            tasks_cb = cb
            return function()
                killed = killed + 1
            end
        end
        scan.scan_project_paths_async = function(_, cb)
            projects_cb = cb
            return function()
                killed = killed + 1
            end
        end
        local calls, failure = 0, nil
        list.list_async({}, function(_, err)
            calls = calls + 1
            failure = err
        end)
        projects_cb(nil, "project failed")
        tasks_cb({}, nil)
        assert.are.equal(1, calls)
        assert.are.equal("project failed", failure)
        assert.are.equal(2, killed)
        local cancel = list.list_async({}, function()
            calls = calls + 1
        end)
        cancel()
        tasks_cb({}, nil)
        projects_cb({}, nil)
        vim.wait(20, function()
            return false
        end, 5)
        assert.are.equal(1, calls)
    end)
end)
