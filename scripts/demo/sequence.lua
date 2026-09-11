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
    p.scene("01 / 07   Tasks stay in your Markdown notes")
    p.hold(3500)
    p.keys(":Tasks<CR>")
    p.tasks("Review the API proposal")
    p.hold(4500)

    p.scene("02 / 07   Filter by tag with #")
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
    p.hold(3000)

    p.scene("03 / 07   Move a due date with Alt + Right")
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
    p.hold(3200)
    p.keys("u")
    p.wait(function()
        return p.line() == before_date
    end, "date undo")
    p.hold(1800)

    p.scene("04 / 07   Enter opens the original note")
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
    p.hold(2200)

    p.scene("05 / 07   Space ti marks it irrelevant, even before saving")
    local edited = p.line()
    p.press("<Space>ti")
    p.wait(function()
        return p.line():find("- [-]", 1, true) and p.line():find("::irrelevant", 1, true)
    end, "irrelevant checkbox and marker")
    p.expect(not p.disk("Studio.md"):find("with the team", 1, true), "action does not save user edits")
    p.hold(4000)

    p.scene("06 / 07   Undo keeps your edits; redo restores the action")
    p.keys("u")
    p.wait(function()
        return p.line() == edited
    end, "native undo preserves typing")
    p.hold(2300)
    p.keys("<C-r>")
    p.wait(function()
        return p.line():find("::irrelevant", 1, true)
    end, "native redo")
    p.hold(1700)
    p.keys(":write<CR>")
    p.wait(function()
        return not vim.bo.modified
    end, "saved source")
    p.expect(p.disk("Studio.md"):find("with the team ::irrelevant", 1, true), "source saved with the action")
    p.hold(1500)

    p.scene("07 / 07   Refresh, then check off a task with Space tx")
    p.keys(":Tasks<CR>")
    p.tasks("Pick up coffee")
    p.expect(not p.text():find("Explore the old dashboard", 1, true), "irrelevant task disappears")
    p.keys("/Pick up coffee<CR>")
    p.press("<Space>tx")
    p.wait(function()
        return p.disk("Home.md"):find("- [x] Pick up coffee", 1, true)
    end, "task checked off")
    p.wait(function()
        return not p.text():find("Pick up coffee", 1, true)
    end, "completed task disappears")
    p.hold(3500)
    p.scene("taskbuffer.nvim   •   Markdown tasks, together in Neovim")
    p.hold(4500)
end

return M
