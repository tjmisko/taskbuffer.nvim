-- E2E test: US date format with custom tag prefix.
-- Verifies config handoff for formats.date and formats.tag_prefix.

vim.opt.rtp:prepend("/plugin")
vim.opt.rtp:prepend("/deps/plenary.nvim")

local h = dofile("/plugin/tests/e2e/helpers.lua")

h.check_setup({
    sources = { "/root/Documents/Notes" },
    formats = {
        date = "%m/%d/%Y",
        tag_prefix = "+",
    },
})
h.check_health()
h.check_tasks()
h.check_content({
    "Dentist appointment",
    "File taxes",
    "Undated US task",
    "+health",
    "+finance",
})
h.finish()
