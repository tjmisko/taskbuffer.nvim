-- E2E test: custom checkbox markers and marker prefix.
-- Verifies config handoff for formats.checkbox and formats.marker_prefix.

vim.opt.rtp:prepend("/plugin")
vim.opt.rtp:prepend("/deps/plenary.nvim")

local h = dofile("/plugin/tests/e2e/helpers.lua")

h.check_setup({
    sources = { "/root/Documents/Notes" },
    formats = {
        checkbox = { open = "TODO ", done = "DONE ", irrelevant = "SKIP " },
        marker_prefix = ">>",
    },
})
h.check_health()
h.check_tasks()
h.check_content({
    "Buy milk",
    "Call plumber",
    "Backlog item",
    "45m",
    "#home",
})
h.check_absent({
    "Already finished",
})
h.finish()
