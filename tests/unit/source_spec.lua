local source = require("taskbuffer.source")

describe("source write safety", function()
    local path, dir
    local function read(target)
        local file = assert(io.open(target or path, "rb"))
        local bytes = file:read("*a")
        file:close()
        return bytes
    end
    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        path = dir .. "/source.md"
        vim.fn.writefile({ "original" }, path)
    end)
    after_each(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(buf):sub(1, #dir) == dir then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        vim.fn.delete(dir, "rf")
    end)

    it("preserves the original file when a write is incomplete", function()
        local original = vim.uv.fs_write
        vim.uv.fs_write = function()
            return nil, "injected disk full"
        end
        local succeeded, ok, err = pcall(source.write, path, "replacement\n")
        vim.uv.fs_write = original
        assert.is_true(succeeded)
        assert.is_false(ok)
        assert.is_truthy(err:find("disk full", 1, true))
        assert.are.equal("original\n", read())
        assert.are.same({ path }, vim.fn.glob(dir .. "/*", true, true))
    end)

    it("does not leave old bytes when replacing a source with shorter content", function()
        assert.is_true(source.write(path, "x\n"))
        assert.are.equal("x\n", read())
    end)

    it("leaves the source intact if metadata copying fails", function()
        local original = vim.system
        vim.system = function()
            return {
                wait = function()
                    return { code = 1, stderr = "metadata copy failed" }
                end,
            }
        end
        local succeeded, ok, err = pcall(source.write, path, "replacement\n")
        vim.system = original
        assert.is_true(succeeded)
        assert.is_false(ok)
        assert.is_truthy(err:find("metadata", 1, true))
        assert.are.equal("original\n", read())
    end)

    it("preserves extended attributes on the replaced file", function()
        local set_args = {
            "python3",
            "-c",
            "import os,sys; os.setxattr(sys.argv[1], 'user.taskbuffer-test', b'kept')",
            path,
        }
        local get_args = {
            "python3",
            "-c",
            "import os,sys; print(os.getxattr(sys.argv[1], 'user.taskbuffer-test').decode())",
            path,
        }
        if vim.uv.os_uname().sysname == "Darwin" then
            set_args = { "xattr", "-w", "user.taskbuffer-test", "kept", path }
            get_args = { "xattr", "-p", "user.taskbuffer-test", path }
        end
        local set = vim.system(set_args, { text = true }):wait()
        assert.are.equal(0, set.code, set.stderr)
        assert.is_true(source.write(path, "replacement\n"))
        local get = vim.system(get_args, { text = true }):wait()
        assert.are.equal(0, get.code, get.stderr)
        assert.are.equal("kept\n", get.stdout)
    end)

    it("preserves permissions when replacing a source", function()
        assert(vim.uv.fs_chmod(path, 416)) -- 0640
        assert.is_true(source.write(path, "replacement\n"))
        assert.are.equal(416, vim.uv.fs_stat(path).mode % 512)
        assert.are.equal("replacement\n", read())
    end)

    it("edits a symlink target without replacing the link", function()
        local link = dir .. "/link.md"
        assert(vim.uv.fs_symlink(path, link))
        assert.is_true(source.write(link, "replacement\n"))
        assert.are.equal("link", vim.uv.fs_lstat(link).type)
        assert.are.equal("replacement\n", read())
    end)

    it("refuses changes through an alias of a modified buffer", function()
        local link = dir .. "/link.md"
        assert(vim.uv.fs_symlink(path, link))
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.api.nvim_set_current_line("unsaved")
        local ok, err = source.write(link, "replacement\n")
        assert.is_false(ok)
        assert.is_truthy(err:find("unsaved", 1, true))
        assert.are.equal("original\n", read())
        assert.are.equal("unsaved", vim.api.nvim_get_current_line())
    end)

    it("discards staged buffer edits on failure and restores disk access", function()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.api.nvim_set_current_line("unsaved")
        local ok, err = source.edit_buffer(0, function()
            assert.are.equal("unsaved\n", source.read(path))
            assert.is_true(source.write(path, "staged\n"))
            return false, "injected failure"
        end)
        assert.is_false(ok)
        assert.are.equal("injected failure", err)
        assert.are.equal("unsaved", vim.api.nvim_get_current_line())
        assert.are.equal("original\n", source.read(path))
        assert.is_false(source.check(path))
    end)

    it("restores disk access when a buffer action raises an error", function()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        local ok, err = source.edit_buffer(0, function()
            assert.is_true(source.write(path, "staged\n"))
            error("injected exception")
        end)
        assert.is_false(ok)
        assert.is_truthy(err:find("injected exception", 1, true))
        assert.are.equal("original", vim.api.nvim_get_current_line())
        assert.are.equal("original\n", source.read(path))
        assert.is_false(vim.bo.modified)
    end)

    it("does not edit readonly buffers or emit W10", function()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.bo.readonly = true
        vim.v.warningmsg = ""
        local called = false
        local ok = source.edit_buffer(0, function()
            called = true
            return source.write(path, "changed\n")
        end)
        assert.is_false(ok)
        assert.is_false(called)
        assert.are.equal("", vim.v.warningmsg)
        assert.are.equal("original", vim.api.nvim_get_current_line())
        assert.are.equal("original\n", read())
    end)

    it("keeps marks on unchanged lines and preserves file options", function()
        vim.fn.writefile({ "heading", "task", "paragraph" }, path)
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.bo.fileformat = "dos"
        vim.bo.endofline = false
        local ns = vim.api.nvim_create_namespace("taskbuffer_source_test")
        local mark = vim.api.nvim_buf_set_extmark(0, ns, 2, 3, {})
        assert.is_true(source.edit_buffer(0, function()
            return source.write(path, "heading\nchanged task\nparagraph")
        end))
        assert.are.same({ 2, 3 }, vim.api.nvim_buf_get_extmark_by_id(0, ns, mark, {}))
        assert.are.equal("dos", vim.bo.fileformat)
        assert.is_false(vim.bo.endofline)
        assert.are.equal("heading\ntask\nparagraph\n", read())
    end)
end)
