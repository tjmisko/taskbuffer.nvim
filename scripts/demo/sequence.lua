-- The storyboard: all visible task actions go through the normal input queue.
local M = {}

function M.fixtures()
    local function date(days)
        local now = os.date("*t")
        now.day, now.hour = now.day + days, 12
        return os.date("%Y-%m-%d", os.time(now))
    end
    return {
        ["Studio.md"] = {
            "# Studio",
            "",
            "A small launch, one task at a time.",
            "",
            "## This week",
            "",
            "- [ ] Review the API proposal #work (@[[" .. date(0) .. "]])",
            "- [ ] Send the release notes #work (@[[" .. date(1) .. "]])",
            "- [ ] Explore the old dashboard #work",
            "",
            "## Ideas",
            "",
            "- [ ] Sketch the next iteration #design",
        },
        ["Home.md"] = {
            "# Away from the desk",
            "",
            "- [ ] Book the bike service #home (@[[" .. date(-1) .. "]])",
            "- [ ] Pick up coffee #home (@[[" .. date(0) .. "]])",
            "- [ ] Plan a weekend ride #home (@[[" .. date(4) .. "]])",
        },
        ["inbox.md"] = { "# Inbox", "", "- [ ] Read about typography #design" },
    }
end

function M.play(p)
    p.scene("01 / 09   Tasks stay in your Markdown notes")
    p.hold(4500)
    p.keys(":Tasks<CR>")
    p.tasks("Review the API proposal")
    local taskbuf = vim.api.nvim_get_current_buf()
    p.hold(6000)

    p.scene("02 / 09   Filter by tag with your picker")
    p.hold(800)
    p.keys("#")
    p.wait(function()
        return vim.bo.filetype == "TelescopePrompt"
    end, "tag picker")
    p.hold(1000)
    p.keys("work")
    p.wait(function()
        local entry = require("telescope.actions.state").get_selected_entry()
        return entry and entry.value == "work"
    end, "work tag selected")
    p.hold(1200)
    p.keys("<CR>")
    p.tasks("Review the API proposal")
    p.expect(not p.text():find("Pick up coffee", 1, true), "tag filter excludes home tasks")
    p.hold(2500)

    p.scene("03 / 09   Alt + arrows move dates; Ctrl-t sets today")
    p.hold(800)
    p.keys("/Review the API<CR>")
    p.wait(function()
        return p.line():find("Review the API", 1, true)
    end, "selected review task")
    local before_date = p.line()
    p.keys("<M-Right>")
    p.tasks("Review the API proposal")
    p.wait(function()
        return p.line() ~= before_date
    end, "date shifted")
    p.hold(2000)
    p.keys("<M-Left>")
    p.tasks("Review the API proposal")
    p.wait(function()
        return p.line() == before_date
    end, "date moved back")
    p.hold(2000)
    p.press("2<M-Right>")
    p.tasks("Review the API proposal")
    p.expect(p.line() ~= before_date, "count moves the date forward again")
    p.hold(2000)
    p.keys("<C-t>")
    p.tasks("Review the API proposal")
    p.expect(p.line() == before_date, "Ctrl-t returns the task to today")
    p.hold(2000)

    p.scene("04 / 09   Enter opens the original note")
    p.hold(1000)
    p.keys("/Explore the old<CR><CR>")
    p.wait(function()
        return vim.bo.filetype == "markdown"
    end, "source note opened")
    p.expect(p.line():find("Explore the old dashboard", 1, true), "jump lands on the task")
    p.hold(2000)
    p.keys("A with the team<Esc>")
    p.wait(function()
        return p.line():find("with the team", 1, true)
    end, "unsaved typing")
    p.expect(vim.bo.modified, "typing leaves unsaved edits")
    p.hold(2000)

    p.scene("05 / 09   Space ti marks it irrelevant, even before saving")
    p.hold(1500)
    local edited = p.line()
    p.press("<Space>ti")
    p.wait(function()
        return p.line():find("- [-]", 1, true) and p.line():find("::irrelevant", 1, true)
    end, "irrelevant checkbox and marker")
    p.expect(not p.disk("Studio.md"):find("with the team", 1, true), "action does not save user edits")
    p.hold(5000)

    p.scene("06 / 09   Undo keeps your edits; redo restores the action")
    p.hold(1500)
    p.keys("u")
    p.wait(function()
        return p.line() == edited
    end, "native undo preserves typing")
    p.hold(3000)
    p.keys("<C-r>")
    p.wait(function()
        return p.line():find("::irrelevant", 1, true)
    end, "native redo")
    p.hold(2500)
    p.keys(":write<CR>")
    p.wait(function()
        return not vim.bo.modified
    end, "saved source")
    p.expect(p.disk("Studio.md"):find("with the team ::irrelevant", 1, true), "source saved with the action")
    p.hold(2000)

    p.scene("07 / 09   Ctrl-o jumps back to the task list")
    p.hold(1000)
    p.keys("<C-o>")
    p.tasks("Review the API proposal")
    p.expect(vim.api.nvim_get_current_buf() == taskbuf, "Ctrl-o returns to the original task buffer")
    p.expect(not p.text():find("Explore the old dashboard", 1, true), "returning refreshes the saved irrelevant task")
    p.hold(2200)

    p.scene("08 / 09   Ctrl-6 switches back from the source")
    p.hold(1000)
    p.keys("/Review the API<CR><CR>")
    p.wait(function()
        return vim.bo.filetype == "markdown"
    end, "source reopened for Ctrl-6")
    p.hold(1200)
    p.keys("<C-6>")
    p.tasks("Review the API proposal")
    p.expect(vim.api.nvim_get_current_buf() == taskbuf, "Ctrl-6 returns to the original task buffer")
    p.hold(2200)

    p.scene("09 / 09   :Tasks returns and refreshes; Space tx checks off")
    p.hold(1000)
    p.keys("<CR>")
    p.wait(function()
        return vim.bo.filetype == "markdown"
    end, "source reopened for :Tasks")
    p.hold(1000)
    p.keys(":Tasks<CR>")
    p.tasks("Pick up coffee")
    p.expect(vim.api.nvim_get_current_buf() == taskbuf, ":Tasks returns to the original task buffer and clears filters")
    p.hold(1000)
    p.keys("/Pick up coffee<CR>")
    p.press("<Space>tx")
    p.wait(function()
        return p.disk("Home.md"):find("- [x] Pick up coffee", 1, true)
    end, "task checked off")
    p.wait(function()
        return not p.text():find("Pick up coffee", 1, true)
    end, "completed task disappears")
    p.hold(2500)
    p.scene("taskbuffer.nvim   •   Markdown tasks, together in Neovim")
    p.hold(3500)
end

return M
