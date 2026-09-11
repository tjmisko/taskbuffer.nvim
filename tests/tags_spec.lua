describe("async tag picker", function()
    local saved, buffer, callbacks, tags, joined, queries, shown, cancelled
    local names = {
        "taskbuffer.tags",
        "taskbuffer.buffer",
        "taskbuffer.list",
        "telescope.pickers",
        "telescope.finders",
        "telescope.config",
        "telescope.actions",
        "telescope.actions.state",
    }
    before_each(function()
        saved = {}
        for _, name in ipairs(names) do
            saved[name] = package.loaded[name]
            package.loaded[name] = nil
        end
        callbacks, queries, shown, cancelled = {}, 0, 0, 0
        joined = nil
        buffer = {
            get_refreshing = function()
                return true
            end,
            get_tag_filter = function()
                return {}
            end,
            refresh_taskfile_async = function(cb)
                joined = cb
            end,
        }
        package.loaded["taskbuffer.buffer"] = buffer
        package.loaded["taskbuffer.list"] = {
            tags_async = function(_, cb)
                queries = queries + 1
                callbacks[queries] = cb
                return function()
                    cancelled = cancelled + 1
                end
            end,
        }
        package.loaded["telescope.pickers"] = {
            new = function()
                return {
                    find = function()
                        shown = shown + 1
                    end,
                }
            end,
        }
        package.loaded["telescope.finders"] = {
            new_table = function(value)
                return value
            end,
        }
        package.loaded["telescope.config"] = { values = { generic_sorter = function() end } }
        package.loaded["telescope.actions"] = {}
        package.loaded["telescope.actions.state"] = {}
        tags = require("taskbuffer.tags")
    end)
    after_each(function()
        tags.cancel(vim.api.nvim_get_current_buf())
        for _, name in ipairs(names) do
            package.loaded[name] = saved[name]
        end
    end)

    it("joins a pending refresh before requesting cached tags", function()
        tags.pick_tags()
        assert.is_function(joined)
        assert.are.equal(0, queries)
        joined()
        assert.are.equal(1, queries)
        callbacks[1]({ "work" })
        assert.are.equal(1, shown)
    end)

    it("does not fetch tags when the source buffer hides while waiting", function()
        tags.pick_tags()
        tags.cancel(vim.api.nvim_get_current_buf())
        joined()
        assert.are.equal(0, queries)
        assert.are.equal(0, shown)
    end)

    it("cancels a tag query and suppresses its late picker", function()
        buffer.get_refreshing = function()
            return false
        end
        tags.pick_tags()
        tags.cancel(vim.api.nvim_get_current_buf())
        assert.are.equal(1, cancelled)
        callbacks[1]({ "work" })
        assert.are.equal(0, shown)
    end)
end)
