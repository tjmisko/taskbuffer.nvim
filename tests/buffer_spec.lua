-- Buffer integration tests.
-- These require the Go binary to be built at go/task_bin.

local tb = require("taskbuffer")

describe("buffer", function()
    local buffer

    before_each(function()
        package.loaded["taskbuffer"] = nil
        package.loaded["taskbuffer.config"] = nil
        package.loaded["taskbuffer.buffer"] = nil
        package.loaded["taskbuffer.keymaps"] = nil
        tb = require("taskbuffer")
        buffer = require("taskbuffer.buffer")
    end)

    it("tasks_clear should reset tag filter", function()
        buffer.set_tag_filter({ "work", "personal" })
        assert.are.same({ "work", "personal" }, buffer.get_tag_filter())

        buffer.clear_tag_filter()
        assert.are.same({}, buffer.get_tag_filter())
    end)

    it("show_markers defaults to false", function()
        assert.is_false(buffer.get_show_markers())
    end)

    it("set_show_markers toggles state", function()
        buffer.set_show_markers(true)
        assert.is_true(buffer.get_show_markers())

        buffer.set_show_markers(false)
        assert.is_false(buffer.get_show_markers())
    end)
end)
