local parse = require("taskbuffer.parse")
local rule = {
    extension = "rs",
    search = "todo!",
    pattern = '^%s*todo!%s*%(%s*"(.-)"%s*%)%s*;?%s*$',
}
local macro = '    todo!("Sum the cart items #code");'

local function annotation(text, cfg, path)
    return parse.parse_task(
        { path = path or "/project/src/lib.rs", line_number = 4, text = text },
        parse.new_parse_context(cfg or { annotations = { rule } })
    )
end

describe("opt-in code annotations", function()
    it("reads a Rust macro without changing its source location or Markdown parsing", function()
        local task = assert(annotation(macro))
        assert.are.equal("Sum the cart items", task.body)
        assert.are.equal("open", task.status)
        assert.are.same({ "code" }, task.tags)
        assert.are.equal("/project/src/lib.rs", task.file_path)
        assert.are.equal(4, task.line_number)
        assert.is_true(task.annotation)
        local note = assert(annotation("- [ ] Normal task #work", nil, "/notes/work.md"))
        assert.is_nil(note.annotation)
        assert.are.equal("Normal task", note.body)
    end)

    it("requires an explicit rule and the matching extension", function()
        assert.is_nil(annotation(macro, {}))
        assert.is_nil(annotation(macro, nil, "/notes/example.md"))
        assert.is_nil(annotation(macro, nil, "/code/example.py"))
    end)

    it("does not treat comments, quoted examples, or empty macros as tasks", function()
        for _, line in ipairs({
            '// todo!("example");',
            'let sample = "todo!()";',
            "todo!();",
            'todo!("");',
            'todo!("multiline',
            'format!("unrelated");',
        }) do
            assert.is_nil(annotation(line), line)
        end
    end)

    it("keeps code tasks open independently of custom checkbox statuses", function()
        local task = assert(annotation(macro, {
            annotations = { rule },
            formats = { checkbox = { pending = "TODO:" } },
        }))
        assert.are.equal("open", task.status)
        assert.is_true(task.annotation)
    end)

    it("supports indentation, optional semicolon, and task metadata", function()
        local task = assert(annotation('\ttodo! ( "Sum items <15m> #code (@[[2026-09-11]])" )'))
        assert.are.equal("Sum items", task.body)
        assert.are.equal("15m", task.duration)
        assert.are.equal("2026-09-11", os.date("%Y-%m-%d", task.due_date))
        assert.are.same({ "code" }, task.tags)
    end)

    for _, fallback in ipairs({ false, true }) do
        for _, async in ipairs({ false, true }) do
            it(
                "scans distinct sources with "
                    .. (fallback and "grep" or "rg")
                    .. (async and " asynchronously" or " synchronously"),
                function()
                    local scan = require("taskbuffer.scan")
                    local root = vim.fn.tempname()
                    for _, name in ipairs({ "work", "personal", "project/src" }) do
                        vim.fn.mkdir(root .. "/" .. name, "p")
                    end
                    vim.fn.writefile({ "- [ ] Work task" }, root .. "/work/tasks.md")
                    vim.fn.writefile({ "- [ ] Personal task" }, root .. "/personal/tasks.md")
                    vim.fn.writefile({ "pub fn total() -> u32 {", macro, "}" }, root .. "/project/src/lib.rs")
                    local ctx = require("taskbuffer.context").build_context({
                        sources = { root .. "/work", root .. "/personal", root .. "/project" },
                        annotations = { rule },
                    }, {})
                    local original = scan._have_rg
                    scan._have_rg = function()
                        return not fallback
                    end
                    local ok, err = pcall(function()
                        local matches, failure
                        if async then
                            local done = false
                            scan.scan_async(ctx, function(result, problem)
                                matches, failure, done = result, problem, true
                            end)
                            assert.is_true(vim.wait(5000, function()
                                return done
                            end, 10))
                        else
                            matches, failure = scan.scan(ctx)
                        end
                        assert.is_nil(failure)
                        assert.are.equal(3, #matches)
                        local tasks = parse.parse_tasks(matches, ctx)
                        assert.are.equal(3, #tasks)
                        local code
                        for _, match in ipairs(matches) do
                            if match.path:match("%.rs$") then
                                code = match
                            end
                        end
                        assert.are.equal(macro, code.text)
                        assert.are.equal(2, code.line_number)
                    end)
                    scan._have_rg = original
                    vim.fn.delete(root, "rf")
                    assert(ok, err)
                end
            )
        end
    end
end)

describe("code annotation interactions", function()
    local editor, path
    before_each(function()
        editor = require("tests.helpers.editor").new()
        vim.fn.mkdir(editor.root .. "/project", "p")
        path = editor.root .. "/project/lib.rs"
        vim.fn.writefile({ "pub fn total(items: &[u32]) -> u32 {", macro, "}" }, path)
        editor.lua(
            [[
            local root, rule = ...
            require('taskbuffer').setup({ sources = {root .. '/vault', root .. '/project'},
                annotations = {rule}, tmpdir = root, state_dir = root .. '/state' })
        ]],
            editor.root,
            rule
        )
    end)
    after_each(function()
        if editor then
            editor.close()
        end
    end)

    local function ready()
        editor.wait(
            [[
            return vim.bo.filetype == 'taskfile' and not require('taskbuffer.buffer').get_refreshing()
                and table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false)):find('Example task',1,true) ~= nil
        ]],
            "list did not refresh"
        )
    end
    local function select_macro()
        editor.command("Tasks")
        ready()
        editor.lua([[
            for row, line in ipairs(vim.api.nvim_buf_get_lines(0,0,-1,false)) do
                if line:find('Sum the cart items',1,true) then
                    vim.api.nvim_win_set_cursor(0,{row,0}); return
                end
            end
            error('missing Rust task')
        ]])
    end

    for _, source in ipairs({ false, true }) do
        it("rejects Markdown mutations in " .. (source and "the code buffer" or "the aggregate list"), function()
            select_macro()
            if source then
                editor.input("<CR>")
                editor.wait("return vim.bo.filetype == 'rust'", "Rust source did not open")
                editor.input("A <Esc>")
                editor.wait("return vim.bo.modified", "source was not edited")
            end
            local disk, before = vim.fn.readfile(path), editor.lines()
            local actions = source and { "<Space>ti", "<Space>tx", "<Space>tc" }
                or { "<Space>ti", "<Space>tx", "<Space>tc", "<M-Right>", "<C-t>", "<Space>tb" }
            for _, keys in ipairs(actions) do
                editor.lua("_G.test_warnings = {}")
                editor.input(keys)
                editor.wait("return #_G.test_warnings > 0", "annotation mutation was not rejected: " .. keys)
                assert.is_truthy(editor.lua("return _G.test_warnings[1]"):find("code annotation", 1, true))
                assert.are.same(disk, vim.fn.readfile(path))
                assert.are.same(before, editor.lines())
            end
        end)
    end

    it("navigates to the macro and refreshes it away after a real source edit", function()
        select_macro()
        local taskbuf = editor.lua("return vim.api.nvim_get_current_buf()")
        editor.input("<CR>")
        editor.wait("return vim.bo.filetype == 'rust'", "Rust source did not open")
        assert.are.equal(macro, editor.lua("return vim.api.nvim_get_current_line()"))
        editor.input("ccitems.iter().sum()<Esc>:write<CR><C-6>")
        ready()
        assert.are.equal(taskbuf, editor.lua("return vim.api.nvim_get_current_buf()"))
        assert.is_nil(table.concat(editor.lines()):find("Sum the cart items", 1, true))
        assert.are.equal("    items.iter().sum()", vim.fn.readfile(path)[2])
        editor.no_warnings()
    end)
end)
