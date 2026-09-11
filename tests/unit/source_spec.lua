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
end)
