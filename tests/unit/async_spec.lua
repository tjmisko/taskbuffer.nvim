local async = require("taskbuffer.async")

describe("cooperative processing", function()
    it("yields to other callbacks and sorts identically to table.sort", function()
        local items = {}
        for i = 4096, 1, -1 do
            items[#items + 1] = i % 37
        end
        local expected = vim.list_slice(items)
        table.sort(expected)
        local done, interleaved = false, false
        async.run(function()
            vim.schedule(function()
                interleaved = true
            end)
            -- A zero deadline makes checkpoint behavior deterministic without
            -- asserting machine-specific durations.
            async.context().deadline = 0
            async.sort(items, function(a, b)
                return a < b
            end)
            assert.is_true(interleaved)
            return items
        end, function(value, err)
            assert.is_nil(err)
            assert.are.same(expected, value)
            done = true
        end)
        assert.is_true(vim.wait(5000, function()
            return done
        end, 5))
    end)

    it("cancels a queued job before any work or callback runs", function()
        local called = false
        local cancel = async.run(function()
            called = true
        end, function()
            called = true
        end)
        cancel()
        vim.wait(20, function()
            return false
        end, 5)
        assert.is_false(called)
    end)

    it("keeps frontmatter caches separate across interleaved jobs", function()
        local fm = require("taskbuffer.frontmatter")
        local path = vim.fn.tempname()
        vim.fn.writefile({ "---", "tags:", "  - first", "---" }, path)
        local done = 0
        async.run(function()
            fm.reset()
            assert.are.same({ "first" }, fm.tags(path))
            coroutine.yield()
            assert.are.same({ "first" }, fm.tags(path))
        end, function(_, err)
            assert.is_nil(err)
            done = done + 1
        end)
        async.run(function()
            vim.fn.writefile({ "---", "tags:", "  - second", "---" }, path)
            fm.reset()
            assert.are.same({ "second" }, fm.tags(path))
        end, function(_, err)
            assert.is_nil(err)
            done = done + 1
        end)
        assert.is_true(vim.wait(1000, function()
            return done == 2
        end, 5))
        vim.fn.delete(path)
    end)
end)
