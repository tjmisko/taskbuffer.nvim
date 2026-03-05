-- E2E test: install via vim-plug in headless Neovim.
-- vim-plug is downloaded at runtime. The plugin source is at /plugin.
-- The Go binary is pre-built in the Docker image.

-- Bootstrap vim-plug
local plug_path = vim.fn.stdpath("data") .. "/site/autoload/plug.vim"
vim.fn.system({
    "curl", "-fLo", plug_path, "--create-dirs",
    "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim",
})
vim.cmd("source " .. plug_path)

-- Register plugin via vim-plug using a local directory
vim.fn["plug#begin"](vim.fn.stdpath("data") .. "/plugged")
vim.fn["plug#"]("/plugin")
vim.fn["plug#end"]()

-- Set up the plugin
require("taskbuffer").setup({
    sources = { "/root/Documents/Notes" },
})

local h = dofile("/plugin/tests/e2e/helpers.lua")

h.check("vim-plug loaded plugin", package.loaded["taskbuffer"] ~= nil, "taskbuffer not in package.loaded")
h.check_health()
h.check_tasks()
h.check_content({
    "Buy groceries",
    "Team meeting",
    "Undated backlog task",
    "#inbox",
})
h.finish()
