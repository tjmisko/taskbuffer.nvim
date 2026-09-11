-- User-facing regressions discovered during the release audit.
describe("release action safety", function()
    local dir, path, tb, buffer, saved_hidden
    local function write(bytes)
        local file = assert(io.open(path, "wb"))
        assert(file:write(bytes))
        assert(file:close())
    end
    local function read()
        local file = assert(io.open(path, "rb"))
        local bytes = file:read("*a")
        file:close()
        return bytes
    end
    local function open_tasks()
        tb.tasks()
        assert.is_true(vim.wait(3000, function()
            return not buffer.get_refreshing()
        end, 5))
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
            if line:find(path, 1, true) then
                vim.api.nvim_win_set_cursor(0, { i, 0 })
                return
            end
        end
        error("expected task missing")
    end
    local function action(description)
        for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
            if mapping.desc == description then
                mapping.callback()
                return
            end
        end
        error("missing mapping: " .. description)
    end
    before_each(function()
        saved_hidden = vim.o.hidden
        vim.o.hidden = true
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. "/vault", "p")
        dir = vim.uv.fs_realpath(dir)
        path = dir .. "/vault/a note:work.md"
        write("- [ ] Example task (@[[2026-02-17]])\n")
        tb = require("taskbuffer")
        tb.setup({ sources = { dir .. "/vault" }, tmpdir = dir, state_dir = dir .. "/new/state" })
        buffer = require("taskbuffer.buffer")
        require("taskbuffer.undo").reset()
    end)
    after_each(function()
        buffer.cancel_refresh()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(buf):sub(1, #dir) == dir then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        vim.o.hidden = saved_hidden
        vim.fn.delete(dir, "rf")
    end)

    it("keeps generated taskfiles in a private session directory", function()
        open_tasks()
        local output = vim.api.nvim_buf_get_name(0)
        assert.are_not.equal(dir .. "/" .. os.date("%Y-%m-%d") .. ".taskfile", output)
        local stat = vim.uv.fs_stat(vim.fn.fnamemodify(output, ":h"))
        assert.are.equal(448, stat.mode % 512) -- 0700
    end)

    it("completes the source task from the aggregate buffer", function()
        open_tasks()
        require("taskbuffer.keymaps").global_action("complete-at")
        assert.is_truthy(read():find("- [x] Example task", 1, true))
        assert.is_truthy(read():find("::complete", 1, true))
    end)

    it("does not discard unsaved Markdown changes for global actions", function()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.api.nvim_buf_set_lines(0, 1, -1, false, { "unsaved paragraph" })
        local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local disk = read()
        require("taskbuffer.keymaps").global_action("complete-at")
        assert.are.same(before, vim.api.nvim_buf_get_lines(0, 0, -1, false))
        assert.are.equal(disk, read())
        assert.is_true(vim.bo.modified)
    end)

    it("protects an unsaved hidden source buffer", function()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        local source_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(source_buf, 1, -1, false, { "unsaved paragraph" })
        open_tasks()
        local disk = read()
        require("taskbuffer.keymaps").global_action("check")
        assert.are.equal(disk, read())
        assert.is_true(vim.bo[source_buf].modified)
        assert.are.equal("unsaved paragraph", vim.api.nvim_buf_get_lines(source_buf, 1, 2, false)[1])
    end)

    it("protects unsaved edits during frontmatter date fallback", function()
        write("---\ndue: 2026-02-17\n---\n- [ ] Example task\n")
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.api.nvim_buf_set_lines(0, 4, -1, false, { "unsaved paragraph" })
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        local disk = read()
        require("taskbuffer.keymaps").markdown_action("shift_date_forward")
        assert.are.equal(disk, read())
        assert.is_true(vim.bo.modified)
        assert.are.equal("unsaved paragraph", vim.api.nvim_buf_get_lines(0, 4, 5, false)[1])
    end)

    it("starts the first timer with a missing state directory", function()
        open_tasks()
        action("Start task")
        local current = require("taskbuffer.state").read_current_task(dir .. "/new/state")
        assert.are.equal(path, current.filepath)
        assert.are.equal(1, current.linenumber)
        assert.are.equal("Example task", current.name)
        assert.is_truthy(read():find("::start", 1, true))
    end)

    it("clears the running timer when completing its source task", function()
        open_tasks()
        action("Start task")
        assert.is_true(vim.wait(3000, function()
            return not buffer.get_refreshing()
        end, 5))
        require("taskbuffer.keymaps").global_action("complete-at")
        assert.is_nil(require("taskbuffer.state").read_current_task(dir .. "/new/state"))
        assert.is_truthy(read():find("- [x] Example task", 1, true))
    end)

    it("ignores headings for actions and source navigation", function()
        open_tasks()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local disk = read()
        assert.has_no.errors(function()
            action("Start task")
            action("Go to task source")
            action("Shift task date forward")
            require("taskbuffer.keymaps").global_action("complete-at")
        end)
        assert.are.equal(disk, read())
    end)

    it("refuses a stale source location after an external insertion", function()
        open_tasks()
        local changed = "- [ ] Different task\n" .. read()
        write(changed)
        require("taskbuffer.keymaps").global_action("check")
        assert.are.equal(changed, read())
    end)

    it("opens a source filename containing spaces, a colon, and an Ex separator", function()
        path = dir .. "/vault/a note:work | task.md"
        write("- [ ] Example task\n")
        open_tasks()
        action("Go to task source")
        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
    end)

    it("keeps a clean loaded source buffer synchronized after completing a task", function()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        local source_buf = vim.api.nvim_get_current_buf()
        open_tasks()
        require("taskbuffer.keymaps").global_action("check")
        assert.are.equal("- [x] Example task (@[[2026-02-17]])", vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
        assert.is_false(vim.bo[source_buf].modified)
        assert.are.equal("taskfile", vim.bo.filetype)
    end)

    it("preserves CRLF and missing final newline during a date edit", function()
        write("title\r\n- [ ] Example task (@[[2026-02-17]])")
        open_tasks()
        action("Shift task date forward")
        assert.are.equal("title\r\n- [ ] Example task (@[[2026-02-18]])", read())
    end)
end)
