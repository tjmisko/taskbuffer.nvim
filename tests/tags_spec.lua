describe("async tag picker", function()
    local saved, buffer, callbacks, tags, joined, queries, shown, cancelled
    local old_select, old_buf, source_buf, choices, selection, notifications, old_notify
    local filter, refreshes
    local names = { "taskbuffer.tags", "taskbuffer.buffer", "taskbuffer.list", "taskbuffer.config" }

    local function flush()
        vim.wait(30, function()
            return false
        end, 5)
    end

    local function open_picker()
        buffer.get_refreshing = function()
            return false
        end
        tags.pick_tags()
        callbacks[queries]({ "home", "work" })
    end

    before_each(function()
        saved = {}
        for _, name in ipairs(names) do
            saved[name] = package.loaded[name]
            package.loaded[name] = nil
        end
        old_select, old_notify = vim.ui.select, vim.notify
        old_buf = vim.api.nvim_get_current_buf()
        source_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(source_buf)
        callbacks, queries, shown, cancelled = {}, 0, 0, 0
        joined, filter, refreshes, notifications = nil, {}, {}, {}
        vim.notify = function(message, level)
            notifications[#notifications + 1] = { message, level }
        end
        buffer = {
            get_refreshing = function()
                return true
            end,
            get_tag_filter = function()
                return filter
            end,
            set_tag_filter = function(value)
                filter = value
            end,
            refresh_taskfile_async = function(cb, opts)
                if cb then
                    joined = cb
                else
                    refreshes[#refreshes + 1] = opts
                end
            end,
        }
        package.loaded["taskbuffer.buffer"] = buffer
        package.loaded["taskbuffer.config"] = { values = {} }
        package.loaded["taskbuffer.list"] = {
            tags_async = function(_, cb)
                queries = queries + 1
                callbacks[queries] = cb
                return function()
                    cancelled = cancelled + 1
                end
            end,
        }
        vim.ui.select = function(items, opts, callback)
            shown = shown + 1
            choices, selection = { items = items, opts = opts }, callback
        end
        tags = require("taskbuffer.tags")
    end)
    after_each(function()
        tags.cancel(source_buf)
        flush()
        vim.ui.select, vim.notify = old_select, old_notify
        vim.api.nvim_set_current_buf(old_buf)
        if vim.api.nvim_buf_is_valid(source_buf) then
            vim.api.nvim_buf_delete(source_buf, { force = true })
        end
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
        tags.cancel(source_buf, true)
        joined()
        assert.are.equal(0, queries)
        assert.are.equal(0, shown)
    end)

    it("cancels a tag query and suppresses its late picker", function()
        buffer.get_refreshing = function()
            return false
        end
        tags.pick_tags()
        tags.cancel(source_buf)
        assert.are.equal(1, cancelled)
        callbacks[1]({ "work" })
        assert.are.equal(0, shown)
    end)

    it("uses the configured select provider and refreshes the source view", function()
        open_picker()
        assert.are.same({ "home", "work" }, choices.items)
        assert.are.equal("taskbuffer_tags", choices.opts.kind)
        assert.are.equal("[ ] work", choices.opts.format_item("work"))
        selection("work", 2)
        flush()
        assert.are.same({ "work" }, filter)
        assert.are.same({ { buf = source_buf, reuse = true } }, refreshes)
    end)

    it("supports multiple tags by toggling choices across picker visits", function()
        filter = { "home" }
        open_picker()
        assert.are.equal("[x] home", choices.opts.format_item("home"))
        selection("work", 2)
        flush()
        assert.are.same({ "home", "work" }, filter)
        open_picker()
        selection("home", 1)
        flush()
        assert.are.same({ "work" }, filter)
        open_picker()
        selection("work", 2)
        flush()
        assert.are.same({}, filter)
    end)

    it("keeps the filter unchanged when the picker is dismissed", function()
        filter = { "home" }
        open_picker()
        selection(nil, nil)
        flush()
        assert.are.same({ "home" }, filter)
        assert.are.same({}, refreshes)
    end)

    it("accepts a synchronous select implementation", function()
        vim.ui.select = function(_, _, on_choice)
            on_choice("work", 2)
        end
        open_picker()
        flush()
        assert.are.same({ "work" }, filter)
    end)

    it("accepts selection before a provider restores the source window", function()
        open_picker()
        local picker_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(picker_buf)
        tags.cancel(source_buf, true)
        selection("work", 2)
        flush()
        assert.are.same({ "work" }, filter)
        assert.are.equal(source_buf, refreshes[1].buf)
        assert.are.equal(picker_buf, vim.api.nvim_get_current_buf())
        vim.api.nvim_buf_delete(picker_buf, { force = true })
    end)

    it("ignores a selection after explicit cancellation", function()
        open_picker()
        tags.cancel(source_buf)
        selection("work", 2)
        flush()
        assert.are.same({}, filter)
        assert.are.same({}, refreshes)
    end)

    it("ignores a selection after the source is wiped", function()
        open_picker()
        vim.api.nvim_buf_delete(source_buf, { force = true })
        selection("work", 2)
        flush()
        assert.are.same({}, refreshes)
    end)

    it("ignores a selection after reconfiguration", function()
        open_picker()
        package.loaded["taskbuffer.config"].values = {}
        selection("work", 2)
        flush()
        assert.are.same({}, refreshes)
    end)

    it("ignores a late choice from a superseded picker", function()
        open_picker()
        local previous = selection
        open_picker()
        previous("home", 1)
        selection("work", 2)
        flush()
        assert.are.same({ "work" }, filter)
        assert.are.equal(1, #refreshes)
    end)

    it("applies a choice only once", function()
        open_picker()
        selection("work", 2)
        selection("work", 2)
        flush()
        assert.are.same({ "work" }, filter)
        assert.are.equal(1, #refreshes)
    end)

    it("reports query errors without opening a picker", function()
        buffer.get_refreshing = function()
            return false
        end
        tags.pick_tags()
        callbacks[1](nil, "scan failed")
        assert.are.equal(0, shown)
        assert.matches("scan failed", notifications[1][1])
    end)
end)
