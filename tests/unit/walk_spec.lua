-- walk.lua: pure-Lua source discovery. Fixtures live under vim.fn.tempname().

local walk = require("taskbuffer.walk")
local async = require("taskbuffer.async")
local uv = vim.uv or vim.loop

local function make_vault()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return assert(uv.fs_realpath(dir))
end

local function write_file(dir, rel, content)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local fd = assert(io.open(path, "wb"))
    fd:write(content or "- [ ] task\n")
    fd:close()
    return path
end

local function relative(dir, files)
    local result = {}
    for _, path in ipairs(files) do
        result[#result + 1] = path:sub(#dir + 2)
    end
    return result
end

local function walked(dir, extra)
    local ctx = vim.tbl_extend("force", { sources = { dir } }, extra or {})
    local files, err = walk.walk(ctx)
    assert.is_nil(err)
    return relative(dir, files)
end

describe("walk.walk recursion rules", function()
    it("should skip hidden files and directories when recursing", function()
        local dir = make_vault()
        write_file(dir, "visible.md")
        write_file(dir, ".hidden.md")
        write_file(dir, ".obsidian/plugin.md")
        write_file(dir, "sub/.secret.md")
        write_file(dir, "sub/kept.md")
        assert.are.same({ "sub/kept.md", "visible.md" }, walked(dir))
    end)

    it("should skip directories named in exclude when recursing", function()
        local dir = make_vault()
        write_file(dir, "keep/a.md")
        write_file(dir, "node_modules/pkg/readme.md")
        write_file(dir, "deep/build/out.md")
        write_file(dir, "custom/skipme/x.md")
        assert.are.same({ "custom/skipme/x.md", "keep/a.md" }, walked(dir, { exclude = { "node_modules", "build" } }))
        assert.are.same({ "keep/a.md" }, walked(dir, { exclude = { "node_modules", "build", "skipme", "deep" } }))
    end)

    it("should apply the default exclude list when the context sets none", function()
        local dir = make_vault()
        write_file(dir, "target/a.md")
        write_file(dir, "dist/a.md")
        write_file(dir, "ok/a.md")
        assert.are.same({ "ok/a.md" }, walked(dir))
    end)

    it("should not follow symlinks found while recursing", function()
        local dir = make_vault()
        local outside = make_vault()
        write_file(outside, "elsewhere.md")
        write_file(dir, "real/a.md")
        assert(uv.fs_symlink(outside, dir .. "/linked-dir"))
        assert(uv.fs_symlink(outside .. "/elsewhere.md", dir .. "/linked-file.md"))
        assert.are.same({ "real/a.md" }, walked(dir))
    end)

    it("should keep only markdown files and configured annotation extensions", function()
        local dir = make_vault()
        write_file(dir, "a.md")
        write_file(dir, "b.txt")
        write_file(dir, "c.rs")
        write_file(dir, "d.py")
        write_file(dir, "noextension")
        assert.are.same({ "a.md" }, walked(dir))
        assert.are.same({ "a.md", "c.rs" }, walked(dir, { annotations = { { extension = "rs", pattern = "(.*)" } } }))
    end)

    it("should detect binary contents when the first 8 KiB hold a NUL byte", function()
        assert.is_true(walk.is_binary("- [ ] task\0more"))
        assert.is_true(walk.is_binary(string.rep("a", 8000) .. "\0"))
        assert.is_false(walk.is_binary(string.rep("a", 9000) .. "\0"))
        assert.is_false(walk.is_binary("- [ ] plain\n"))
    end)

    it("should find deeply nested files and directories with spaces", function()
        local dir = make_vault()
        write_file(dir, "a/b/c/d/deep.md")
        write_file(dir, "space dir/note.md")
        assert.are.same({ "a/b/c/d/deep.md", "space dir/note.md" }, walked(dir))
    end)

    it("should return nothing when the directory is empty", function()
        assert.are.same({}, walked(make_vault()))
    end)

    it("should return sorted absolute paths", function()
        local dir = make_vault()
        write_file(dir, "z.md")
        write_file(dir, "a.md")
        write_file(dir, "m/b.md")
        local files = assert(walk.walk({ sources = { dir } }))
        assert.are.same({ dir .. "/a.md", dir .. "/m/b.md", dir .. "/z.md" }, files)
    end)

    it("should work inside an async slice when the tree is large", function()
        local dir = make_vault()
        for i = 1, 60 do
            write_file(dir, "d" .. i .. "/n.md")
        end
        local result, done
        async.run(function()
            return (walk.walk({ sources = { dir } }))
        end, function(value)
            result, done = value, true
        end)
        assert.is_true(vim.wait(5000, function()
            return done
        end, 5))
        assert.are.equal(60, #result)
    end)
end)

describe("walk.walk sources", function()
    it("should pass a single-file source through when it has any extension or hidden name", function()
        local dir = make_vault()
        local hidden = write_file(dir, ".dot.txt")
        local files = assert(walk.walk({ sources = { hidden } }))
        assert.are.same({ uv.fs_realpath(hidden) }, files)
    end)

    it("should return an error when a source does not exist", function()
        local files, err = walk.walk({ sources = { "/nonexistent/path/that/does/not/exist" } })
        assert.is_nil(files)
        assert.is_truthy(err:find("not found", 1, true))
    end)

    it("should return nothing and no error when there are no sources", function()
        local files, err = walk.walk({ sources = {} })
        assert.is_nil(err)
        assert.are.same({}, files)
    end)

    it("should union two directories when both are sources", function()
        local one, two = make_vault(), make_vault()
        write_file(one, "a.md")
        write_file(two, "b.md")
        local files = assert(walk.walk({ sources = { one, two } }))
        assert.are.equal(2, #files)
    end)

    it("should expand * and ? globs to matching directories", function()
        local dir = make_vault()
        write_file(dir, "notes-1/a.md")
        write_file(dir, "notes-2/b.md")
        write_file(dir, "notes-3/c.md")
        write_file(dir, "extra.md")
        assert.are.equal(3, #assert(walk.walk({ sources = { dir .. "/notes-*" } })))
        assert.are.equal(3, #assert(walk.walk({ sources = { dir .. "/notes-?" } })))
        assert.are.equal(4, #assert(walk.walk({ sources = { dir .. "/*" } })))
        assert.are.equal(0, #assert(walk.walk({ sources = { dir .. "/nonexist-*" } })))
    end)

    it("should not treat [ as a glob character", function()
        local dir = make_vault()
        local path = write_file(dir, "[a].md")
        assert.are.same({ uv.fs_realpath(path) }, assert(walk.walk({ sources = { path } })))
    end)

    it("should dedup a real directory and a symlink to it", function()
        local dir = make_vault()
        local real = dir .. "/symlink-target"
        write_file(dir, "symlink-target/t.md")
        assert(uv.fs_symlink(real, dir .. "/linked"))
        assert.are.equal(1, #assert(walk.walk({ sources = { real, dir .. "/linked" } })))
    end)

    it("should dedup overlapping parent and nested sources to the parent", function()
        local dir = make_vault()
        write_file(dir, "deeply/nested/dir/note.md")
        assert.are.equal(1, #assert(walk.walk({ sources = { dir .. "/deeply", dir .. "/deeply/nested/dir" } })))
    end)

    it("should return each file once when a source is duplicated exactly", function()
        local dir = make_vault()
        write_file(dir, "normal/n.md")
        assert.are.equal(1, #assert(walk.walk({ sources = { dir .. "/normal", dir .. "/normal" } })))
    end)

    it("should find files below the parent without following the linked directory", function()
        local dir = make_vault()
        write_file(dir, "normal/a.md")
        write_file(dir, "symlink-target/d.md")
        assert(uv.fs_symlink(dir .. "/symlink-target", dir .. "/linked"))
        assert.are.same({ "normal/a.md", "symlink-target/d.md" }, walked(dir))
    end)
end)

describe("walk.deduplicate_paths", function()
    it("should drop a nested path in favor of its parent", function()
        local dir = make_vault()
        vim.fn.mkdir(dir .. "/sub", "p")
        assert.are.same({ dir }, walk.deduplicate_paths({ dir, dir .. "/sub" }))
    end)

    it("should not let /a/b absorb /a/bcd", function()
        local dir = make_vault()
        vim.fn.mkdir(dir .. "/b", "p")
        vim.fn.mkdir(dir .. "/bcd", "p")
        assert.are.equal(2, #walk.deduplicate_paths({ dir .. "/b", dir .. "/bcd" }))
    end)

    it("should keep a nonexistent path as given", function()
        assert.are.same({ "/nonexistent/path/xyz" }, walk.deduplicate_paths({ "/nonexistent/path/xyz" }))
    end)
end)

describe("walk.accepts_below", function()
    it("should reject paths outside the root, hidden components, excluded directories, and other extensions", function()
        local ctx = { exclude = { "build" } }
        assert.is_true(walk.accepts_below("/r/a/b.md", "/r", ctx))
        assert.is_false(walk.accepts_below("/other/b.md", "/r", ctx))
        assert.is_false(walk.accepts_below("/rx/b.md", "/r", ctx))
        assert.is_false(walk.accepts_below("/r/.git/b.md", "/r", ctx))
        assert.is_false(walk.accepts_below("/r/build/b.md", "/r", ctx))
        assert.is_false(walk.accepts_below("/r/a/b.txt", "/r", ctx))
    end)
end)
