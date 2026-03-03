local tb = require("taskbuffer")

describe("config_json_arg", function()
    before_each(function()
        -- Reset module to defaults by reloading
        package.loaded["taskbuffer"] = nil
        package.loaded["taskbuffer.config"] = nil
        tb = require("taskbuffer")
    end)

    it("should include all 7 fields with default config", function()
        tb.setup({})
        local json_str = tb.config_json_arg()
        local decoded = vim.json.decode(json_str)

        assert.is_not_nil(decoded.state_dir, "state_dir missing")
        assert.is_not_nil(decoded.date_format, "date_format missing")
        assert.is_not_nil(decoded.time_format, "time_format missing")
        assert.is_not_nil(decoded.date_wrapper, "date_wrapper missing")
        assert.is_not_nil(decoded.marker_prefix, "marker_prefix missing")
        assert.is_not_nil(decoded.tag_prefix, "tag_prefix missing")
        assert.is_not_nil(decoded.checkbox, "checkbox missing")
    end)

    it("should reflect format overrides", function()
        tb.setup({ formats = { tag_prefix = "@" } })
        local json_str = tb.config_json_arg()
        local decoded = vim.json.decode(json_str)

        assert.are.equal("@", decoded.tag_prefix)
    end)

    it("should pass custom marker_prefix", function()
        tb.setup({ formats = { marker_prefix = ">>" } })
        local json_str = tb.config_json_arg()
        local decoded = vim.json.decode(json_str)

        assert.are.equal(">>", decoded.marker_prefix)
    end)

    it("should pass custom checkbox values", function()
        tb.setup({
            formats = {
                checkbox = { open = "- { }", done = "- {x}", irrelevant = "- {-}" },
            },
        })
        local json_str = tb.config_json_arg()
        local decoded = vim.json.decode(json_str)

        assert.are.equal("- { }", decoded.checkbox.open)
        assert.are.equal("- {x}", decoded.checkbox.done)
        assert.are.equal("- {-}", decoded.checkbox.irrelevant)
    end)
end)

describe("source_args", function()
    before_each(function()
        package.loaded["taskbuffer"] = nil
        package.loaded["taskbuffer.config"] = nil
        tb = require("taskbuffer")
    end)

    it("should build --source flags from sources", function()
        tb.setup({ sources = { "/tmp/a", "/tmp/b" } })
        local args = tb.source_args()

        assert.are.same({ "--source", "/tmp/a", "--source", "/tmp/b" }, args)
    end)

    it("should handle single source", function()
        tb.setup({ sources = { "/tmp/only" } })
        local args = tb.source_args()

        assert.are.same({ "--source", "/tmp/only" }, args)
    end)
end)

describe("deep_merge", function()
    before_each(function()
        package.loaded["taskbuffer"] = nil
        package.loaded["taskbuffer.config"] = nil
        tb = require("taskbuffer")
    end)

    it("should preserve false values for keymaps", function()
        tb.setup({ keymaps = { global = { complete = false } } })

        assert.is_false(tb.config.keymaps.global.complete)
        -- Other keys should remain intact
        assert.is_not_nil(tb.config.keymaps.global.defer)
        assert.is_not_nil(tb.config.keymaps.taskfile.start_task)
    end)

    it("should not clobber sibling keys", function()
        tb.setup({ formats = { tag_prefix = "@" } })

        -- tag_prefix should be overridden
        assert.are.equal("@", tb.config.formats.tag_prefix)
        -- Other format keys should remain at defaults
        assert.are.equal("::", tb.config.formats.marker_prefix)
        assert.are.equal("%Y-%m-%d", tb.config.formats.date)
    end)
end)

describe("notes_dir backward compat", function()
    before_each(function()
        package.loaded["taskbuffer"] = nil
        package.loaded["taskbuffer.config"] = nil
        tb = require("taskbuffer")
    end)

    it("should convert notes_dir to sources", function()
        tb.setup({ notes_dir = "/tmp/notes" })

        assert.are.equal("/tmp/notes", tb.config.sources[1])
    end)
end)
