-- E2E test: European date format with simple wrapper.
-- Verifies config handoff for formats.date and 2-element date_wrapper.

vim.opt.rtp:prepend("/plugin")
vim.opt.rtp:prepend("/deps/plenary.nvim")

local h = dofile("/plugin/tests/e2e/helpers.lua")

h.check_setup({
    sources = { "/root/Documents/Notes" },
    formats = {
        date = "%d.%m.%Y",
        date_wrapper = { "{", "}" },
    },
})
h.check_health()
h.check_tasks()
h.check_content({
    "Arzttermin",
    "Steuern abgeben",
    "Undated EU task",
    "#health",
})
h.finish()
