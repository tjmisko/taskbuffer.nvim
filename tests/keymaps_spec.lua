local tb = require("taskbuffer")

describe("keymaps", function()
    before_each(function()
        -- Clear global keymaps that may persist from previous tests
        local leader = vim.g.mapleader or "\\"
        for _, suffix in ipairs({ "tc", "td", "tx", "ti", "tu", "ev", "zz" }) do
            pcall(vim.keymap.del, "n", leader .. suffix)
        end

        -- Reset module state
        package.loaded["taskbuffer"] = nil
        package.loaded["taskbuffer.config"] = nil
        package.loaded["taskbuffer.keymaps"] = nil
        package.loaded["taskbuffer.buffer"] = nil
        tb = require("taskbuffer")
    end)

    it("should register keymaps for taskfile filetype", function()
        tb.setup({})

        -- Simulate a taskfile buffer
        vim.cmd("enew")
        vim.bo.filetype = "taskfile"
        vim.api.nvim_exec_autocmds("FileType", { pattern = "taskfile" })

        -- Check that buffer-local keymap for go_to_file exists
        local keymaps = vim.api.nvim_buf_get_keymap(0, "n")
        local found_gf = false
        for _, km in ipairs(keymaps) do
            if km.lhs == "gf" then
                found_gf = true
            end
        end
        assert.is_true(found_gf, "gf keymap should exist in taskfile buffer")

        vim.cmd("bdelete!")
    end)

    it("should not register disabled keymaps", function()
        tb.setup({ keymaps = { global = { complete = false } } })

        -- Check global keymaps - complete should not be registered
        local keymaps = vim.api.nvim_get_keymap("n")
        local found_complete = false
        for _, km in ipairs(keymaps) do
            if km.lhs == "<leader>tc" then
                found_complete = true
            end
        end
        assert.is_false(found_complete, "<leader>tc should not be registered when complete=false")
    end)

    it("should use custom key bindings", function()
        tb.setup({ keymaps = { global = { complete = "<leader>zz" } } })

        -- Neovim normalizes <leader> to the actual leader key (default: \)
        local leader = vim.g.mapleader or "\\"
        local expected_custom = leader .. "zz"
        local expected_default = leader .. "tc"

        local keymaps = vim.api.nvim_get_keymap("n")
        local found_custom = false
        local found_default = false
        for _, km in ipairs(keymaps) do
            if km.lhs == expected_custom then
                found_custom = true
            end
            if km.lhs == expected_default then
                found_default = true
            end
        end
        assert.is_true(found_custom, expected_custom .. " should be registered as custom complete keymap")
        assert.is_false(found_default, expected_default .. " should not be registered when overridden")
    end)
end)
