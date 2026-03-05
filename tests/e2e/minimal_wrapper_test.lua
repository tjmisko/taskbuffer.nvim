-- E2E test: minimal date wrapper with custom tag prefix.
-- Verifies config handoff for 2-element date_wrapper and tag_prefix.

vim.opt.rtp:prepend("/plugin")
vim.opt.rtp:prepend("/deps/plenary.nvim")

local h = dofile("/plugin/tests/e2e/helpers.lua")

h.check_setup({
    sources = { "/root/Documents/Notes" },
    formats = {
        date_wrapper = { "[", "]" },
        tag_prefix = "@",
    },
})
h.check_health()
h.check_tasks()
h.check_content({
    "Read chapter 3",
    "Submit PR",
    "Someday item",
    "@books",
    "@work",
})
h.finish()
