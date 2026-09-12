-- The storyboard: all visible task actions go through the normal input queue.
local M = {}

function M.fixtures()
    local function date(days)
        local now = os.date("*t")
        now.day, now.hour = now.day + days, 12
        return os.date("%Y-%m-%d", os.time(now))
    end
    return {
        ["vault/Studio.md"] = {
            "# Studio",
            "",
            "A small launch, one task at a time.",
            "",
            "## This week",
            "",
            "- [ ] Review the API proposal #work (@[[" .. date(0) .. "]])",
            "- [ ] Send the release notes #work (@[[" .. date(1) .. "]])",
            "- [ ] Explore the dashboard #work",
            "",
            "## Ideas",
            "",
            "- [ ] Sketch the next iteration #design",
        },
        ["personal/Home.md"] = {
            "# Away from the desk",
            "",
            "- [ ] Book the bike service #home (@[[" .. date(-1) .. "]])",
            "- [ ] Pick up coffee #home (@[[" .. date(0) .. "]])",
            "- [ ] Plan a weekend ride #home (@[[" .. date(4) .. "]])",
        },
        ["project/src/lib.rs"] = {
            "// Tasks can live beside the code they describe.",
            "",
            "pub fn total(items: &[u32]) -> u32 {",
            '    todo!("Sum the cart items #code");',
            "}",
        },
        ["vault/inbox.md"] = { "# Inbox", "", "- [ ] Read about typography #design" },
    }
end

function M.play(p)
    p.scene("01 / 09   Work notes, personal notes, and code")
    p.hold(1800)
    p.keys(":Tasks<CR>")
    p.tasks("Review the API proposal")
    local taskbuf = vim.api.nvim_get_current_buf()
    p.expect(p.text():find("Pick up coffee", 1, true), "personal source included")
    p.expect(p.text():find("Sum the cart items", 1, true), "Rust source included")
    p.hold(2600)

    p.scene("02 / 09   Filter by tag with your picker")
    p.hold(250)
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
    p.hold(1100)

    p.scene("03 / 09   Move dates both ways; Ctrl-t sets today")
    p.hold(250)
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
    p.hold(850)
    p.keys("<M-Left>")
    p.tasks("Review the API proposal")
    p.wait(function()
        return p.line() == before_date
    end, "date moved back")
    p.hold(850)
    p.press("2<M-Right>")
    p.tasks("Review the API proposal")
    p.expect(p.line() ~= before_date, "count moves the date forward again")
    p.hold(850)
    p.keys("<C-t>")
    p.tasks("Review the API proposal")
    p.expect(p.line() == before_date, "Ctrl-t returns the task to today")
    p.hold(850)

    p.scene("04 / 09   Enter opens the original note")
    p.hold(1000)
    p.keys("/Explore the dashboard<CR><CR>")
    p.wait(function()
        return vim.bo.filetype == "markdown"
    end, "source note opened")
    p.expect(p.line():find("Explore the dashboard", 1, true), "jump lands on the task")
    p.hold(850)
    p.keys("A with the team<Esc>")
    p.wait(function()
        return p.line():find("with the team", 1, true)
    end, "unsaved typing")
    p.expect(vim.bo.modified, "typing leaves unsaved edits")
    p.hold(850)

    p.scene("05 / 09   Space ti works before saving")
    p.hold(350)
    local edited = p.line()
    p.press("<Space>ti")
    p.wait(function()
        return p.line():find("- [-]", 1, true) and p.line():find("::irrelevant", 1, true)
    end, "irrelevant checkbox and marker")
    p.expect(not p.disk("vault/Studio.md"):find("with the team", 1, true), "action does not save user edits")
    p.hold(1800)

    p.scene("06 / 09   Undo, redo, then save")
    p.hold(350)
    p.keys("u")
    p.wait(function()
        return p.line() == edited
    end, "native undo preserves typing")
    p.hold(900)
    p.keys("<C-r>")
    p.wait(function()
        return p.line():find("::irrelevant", 1, true)
    end, "native redo")
    p.hold(1100)
    p.keys(":write<CR>")
    p.wait(function()
        return not vim.bo.modified
    end, "saved source")
    p.expect(p.disk("vault/Studio.md"):find("with the team ::irrelevant", 1, true), "source saved with the action")
    p.expect(
        table.concat(require("keys").history, " "):find(":write Enter", 1, true),
        "key display keeps commands together"
    )
    p.hold(850)

    p.scene("07 / 09   Ctrl-o jumps back to the task list")
    p.hold(1000)
    p.keys("<C-o>")
    p.tasks("Review the API proposal")
    p.expect(vim.api.nvim_get_current_buf() == taskbuf, "Ctrl-o returns to the original task buffer")
    p.expect(not p.text():find("Explore the dashboard", 1, true), "returning refreshes the saved irrelevant task")
    p.hold(2200)

    p.scene("08 / 09   :Tasks returns and refreshes all sources")
    p.keys("/Review the API<CR><CR>")
    p.wait(function()
        return vim.bo.filetype == "markdown"
    end, "source reopened for :Tasks")
    p.hold(650)
    p.keys(":Tasks<CR>")
    p.tasks("Pick up coffee")
    p.expect(vim.api.nvim_get_current_buf() == taskbuf, ":Tasks returns to the original task buffer and clears filters")
    p.hold(1000)

    p.scene("09 / 09   Resolve a Rust todo!; Ctrl-6 returns")
    p.keys("/Sum the cart<CR><CR>")
    p.wait(function()
        return vim.bo.filetype == "rust"
    end, "Rust source opened")
    p.expect(p.line():find('todo!("Sum the cart items #code");', 1, true), "jump lands on the real Rust macro")
    p.hold(1800)
    p.keys("ccitems.iter().sum()<Esc>:write<CR>")
    p.wait(function()
        return not vim.bo.modified and p.line():find("items.iter().sum()", 1, true)
    end, "Rust implementation saved")
    p.expect(not p.disk("project/src/lib.rs"):find("todo!", 1, true), "resolved macro removed from code")
    p.hold(1400)
    p.keys("<C-6>")
    p.tasks("Pick up coffee")
    p.expect(vim.api.nvim_get_current_buf() == taskbuf, "Ctrl-6 returns to the original task buffer")
    p.expect(not p.text():find("Sum the cart items", 1, true), "return refresh removes resolved Rust task")
    p.hold(1600)
    p.keys("/Pick up coffee<CR>")
    p.press("<Space>tx")
    p.wait(function()
        return p.disk("personal/Home.md"):find("- [x] Pick up coffee", 1, true)
    end, "task checked off in the personal source")
    p.wait(function()
        return not p.text():find("Pick up coffee", 1, true)
    end, "completed task disappears")
    p.hold(1200)
    p.scene("taskbuffer.nvim   •   Your tasks, across files")
    p.hold(2200)
end

return M
