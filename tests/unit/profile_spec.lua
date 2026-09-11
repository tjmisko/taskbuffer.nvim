local profile = require("taskbuffer.profile")

local function stage(name)
    for _, row in ipairs(profile.snapshot().stages) do
        if row.name == name then
            return row
        end
    end
end

describe("performance recording", function()
    before_each(function()
        profile.stop()
        profile.reset()
    end)

    after_each(function()
        profile.stop()
        profile.reset()
    end)

    it("does no timing work while disabled", function()
        local original = vim.uv.hrtime
        local calls = 0
        vim.uv.hrtime = function()
            calls = calls + 1
            return original()
        end
        local ok, err = pcall(function()
            assert.is_nil(profile.begin("disabled"))
            assert.are.equal(
                42,
                profile.measure("disabled", function()
                    return 42
                end)
            )
            profile.finish(nil)
        end)
        vim.uv.hrtime = original
        assert.is_true(ok, err)
        assert.are.equal(0, calls)
        assert.are.same({}, profile.snapshot().stages)
    end)

    it("preserves nil returns and records errors before rethrowing", function()
        profile.start()
        local wrapped = profile.wrap("returns", function(a, b)
            return nil, a + b, nil
        end)
        local function check(...)
            assert.are.equal(3, select("#", ...))
            assert.is_nil(select(1, ...))
            assert.are.equal(5, select(2, ...))
        end
        check(wrapped(2, 3))
        local failure = {}
        local ok, err = pcall(profile.measure, "failure", function()
            error(failure)
        end)
        assert.is_false(ok)
        assert.are.equal(failure, err)
        assert.are.equal(1, stage("returns").count)
        assert.are.equal(1, stage("failure").count)
    end)

    it("bounds retained samples and reports correct aggregate timings", function()
        profile.start()
        local original = vim.uv.hrtime
        local now = original()
        vim.uv.hrtime = function()
            return now
        end
        for i = 1, 300 do
            local span = profile.begin("bounded")
            now = now + i * 1e6
            profile.finish(span)
        end
        vim.uv.hrtime = original
        local row = stage("bounded")
        assert.are.equal(300, row.count)
        assert.are.equal(256, row.sample_count)
        assert.are.equal(45150, row.total_ms)
        assert.are.equal(150.5, row.mean_ms)
        assert.are.equal(300, row.max_ms)
        assert.are.equal(288, row.p95_ms)
        row.count = 0
        assert.are.equal(300, stage("bounded").count)
    end)

    it("ignores spans that cross reset/stop and duplicate completions", function()
        profile.start()
        local old = profile.begin("old")
        profile.reset()
        profile.finish(old)
        local current = profile.begin("current")
        profile.finish(current)
        profile.finish(current)
        assert.are.equal(1, stage("current").count)
        local stopped = profile.begin("stopped")
        profile.stop()
        profile.finish(stopped)
        profile.start()
        profile.finish(stopped)
        assert.is_nil(stage("old"))
        assert.is_nil(stage("stopped"))
    end)

    it("observes a main-loop stall and stops its probe", function()
        profile.start()
        -- uv.sleep blocks instead of pumping Neovim's event loop like vim.wait.
        vim.uv.sleep(70)
        assert.is_true(vim.wait(1000, function()
            return stage("event_loop.delay") ~= nil
        end, 5))
        assert.is_true(stage("event_loop.delay").max_ms >= 40)
        profile.stop()
        local count = stage("event_loop.delay").count
        vim.wait(60, function()
            return false
        end, 5)
        assert.are.equal(count, stage("event_loop.delay").count)
        assert.is_false(profile.snapshot().enabled)
    end)

    it("records synchronous and asynchronous pipeline stages without changing output", function()
        local config = require("taskbuffer.config")
        local saved = config.values
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({ "- [ ] Example #work (@[[2026-09-11]])" }, dir .. "/tasks.md")
        config.apply({ sources = { dir }, state_dir = dir, tmpdir = dir, inbox = { file = dir .. "/inbox.md" } })
        local ok, err = pcall(function()
            local list = require("taskbuffer.list")
            local baseline, baseline_err = list.list()
            assert.is_nil(baseline_err)
            profile.start()
            local sync, sync_err = list.list()
            assert.is_nil(sync_err)
            assert.are.equal(baseline, sync)
            local done, async, async_err = false, nil, nil
            list.list_async({}, function(text, failure)
                async, async_err, done = text, failure, true
            end)
            assert.is_true(vim.wait(5000, function()
                return done
            end, 5))
            assert.is_nil(async_err)
            assert.are.equal(baseline, async)
            assert.are.equal(1, stage("list.sync").count)
            assert.are.equal(1, stage("list.async.wall").count)
            assert.are.equal(2, stage("parse").count)
            assert.are.equal(1, stage("scan.projects.sync").count)
            assert.are.equal(1, stage("scan.projects.async").count)
            assert.are.equal(2, stage("scan.schedule_delay").count)
        end)
        config.values = saved
        vim.fn.delete(dir, "rf")
        assert.is_true(ok, err)
    end)
end)
