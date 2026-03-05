-- E2E smoke test: runs in headless Neovim inside Docker.
-- Verifies setup, checkhealth, and :Tasks output with direct rtp setup.

vim.opt.rtp:prepend("/plugin")
vim.opt.rtp:prepend("/deps/plenary.nvim")

local h = dofile("/plugin/tests/e2e/helpers.lua")

h.check_setup()
h.check_health()
h.check_tasks()
h.check_content({
    "Buy groceries",
    "Team meeting",
    "Undated backlog task",
    "#inbox",
})
h.finish()
