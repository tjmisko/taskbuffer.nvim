-- E2E test: install via lazy.nvim in headless Neovim.
-- The plugin source is at /plugin (copied into the container).
-- Go toolchain is available so the build hook can run.

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.fn.system({
    "git", "clone", "--filter=blob:none", "--branch=stable",
    "https://github.com/folke/lazy.nvim.git", lazypath,
})
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
    {
        dir = "/plugin",
        config = function()
            require("taskbuffer").setup({
                sources = { "/root/Documents/Notes" },
            })
        end,
    },
})

local h = dofile("/plugin/tests/e2e/helpers.lua")

h.check("lazy.nvim loaded plugin", package.loaded["taskbuffer"] ~= nil, "taskbuffer not in package.loaded")
h.check_health()
h.check_tasks()
h.check_content({
    "Buy groceries",
    "Team meeting",
    "Undated backlog task",
    "#inbox",
})
h.finish()
