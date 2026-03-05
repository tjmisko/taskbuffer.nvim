-- E2E test: 12-hour time format.
-- Verifies config handoff for formats.time with AM/PM.

vim.opt.rtp:prepend("/plugin")
vim.opt.rtp:prepend("/deps/plenary.nvim")

local h = dofile("/plugin/tests/e2e/helpers.lua")

h.check_setup({
    sources = { "/root/Documents/Notes" },
    formats = {
        time = "%I:%M %p",
    },
})
h.check_health()
h.check_tasks()
h.check_content({
    "Morning standup",
    "Lunch meeting",
    "Evening review",
    "12:30 PM",
    "#review",
})
h.finish()
