-- Verify buffer.lua routes through list.lua (not the binary) when
-- use_lua_pipeline is set, and writes the byte-exact taskfile to disk.

local parity = require("tests.helpers.parity")

if vim.fn.executable(parity.task_bin) ~= 1 then
    describe("buffer wiring", function()
        pending("go/task_bin not built")
    end)
    return
end

local function read_file(path)
    local fh = assert(io.open(path, "r"))
    local data = fh:read("*a")
    fh:close()
    return data
end

describe("buffer wiring (use_lua_pipeline)", function()
    local buffer = require("taskbuffer.buffer")

    before_each(function()
        buffer.clear_tag_filter()
        buffer.set_show_markers(false)
        buffer.set_show_undated(true)
        buffer.set_refreshing(false)
    end)

    it("refresh_taskfile writes Go-identical bytes when the flag is on", function()
        local vault = parity.copy_vault("basic-vault")
        local out = vim.fn.tempname()
        vim.fn.mkdir(out, "p")
        require("taskbuffer.config").apply({ sources = { vault }, tmpdir = out, use_lua_pipeline = true })

        local golden = parity.go_list(vault, {})
        buffer.refresh_taskfile()

        local written = read_file(out .. "/" .. os.date("%Y-%m-%d") .. ".taskfile")
        assert.are.equal(golden, written)
    end)

    it("run_task_cmd routes 'check' to actions and writes Go-identical bytes", function()
        require("taskbuffer.config").apply({ use_lua_pipeline = true })
        local f_go = parity.copy_file("basic-vault", "daily.md")
        local go_bytes = parity.go_verb(f_go, 3, "check")

        local f_lua = parity.copy_file("basic-vault", "daily.md")
        local ok = require("taskbuffer.util").run_task_cmd({ "check", f_lua, "3" }, false)
        assert.is_true(ok)
        local fh = assert(io.open(f_lua, "r"))
        local got = fh:read("*a")
        fh:close()
        assert.are.equal(go_bytes, got)
    end)

    it("honors show_markers + ignore_undated through the wiring", function()
        local vault = parity.copy_vault("basic-vault")
        local out = vim.fn.tempname()
        vim.fn.mkdir(out, "p")
        require("taskbuffer.config").apply({ sources = { vault }, tmpdir = out, use_lua_pipeline = true })

        buffer.set_show_markers(true)
        buffer.set_show_undated(false)
        local golden = parity.go_list(vault, { "--markers", "--ignore-undated" })
        buffer.refresh_taskfile()

        local written = read_file(out .. "/" .. os.date("%Y-%m-%d") .. ".taskfile")
        assert.are.equal(golden, written)
    end)
end)
