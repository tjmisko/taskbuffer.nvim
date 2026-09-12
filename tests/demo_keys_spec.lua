describe("demo screencast keys", function()
    local keys
    before_each(function()
        keys = dofile("scripts/demo/keys.lua")
    end)

    local function record(input, mode)
        keys.record(vim.api.nvim_replace_termcodes(input, true, false, true), mode or "n")
    end

    it("keeps commands and typed words together, with chords separated", function()
        record("u")
        record("<C-r>")
        for char in (":write"):gmatch(".") do
            record(char, "c")
        end
        record("<CR>", "c")
        assert.are.same({ "u", "Ctrl-r", ":write", "Enter" }, keys.history)
        keys.scene("typing")
        for char in ("with the team"):gmatch(".") do
            record(char, "i")
        end
        record("<Esc>", "i")
        record("<Space>")
        record("t")
        record("i")
        assert.are.same({ "with the team", "<Esc>", "Space", "ti" }, keys.history)
    end)

    it("bounds long typed text to the display width without corrupting Unicode", function()
        for _ = 1, 100 do
            record("界", "i")
        end
        local text = table.concat(keys.history, " ")
        assert.is_true(vim.fn.strdisplaywidth(text) <= 58)
        assert.are.equal(0, #text % #"界")
        assert.are.equal(100, #keys.log)
    end)
end)
