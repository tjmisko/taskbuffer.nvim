-- Regression coverage for the file-reading helpers in util.lua.
--
-- A taskfile line points back at a source note (`path:line:...`). That note can
-- be deleted or renamed after the taskfile was generated; when it is, the
-- helpers must degrade gracefully instead of letting io.lines() raise. The
-- crash this guards against: shifting a task date on a line whose source note
-- no longer exists.
--
-- Fixtures are written under vim.fn.tempname() (OS tempdir), never the worktree.

local util = require("taskbuffer.util")

-- Write content bytes to a fresh temp .md file, return its path.
local function temp_md(content)
    local path = vim.fn.tempname() .. ".md"
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
    return path
end

-- A temp path that does NOT exist on disk.
local function missing_path()
    return vim.fn.tempname() .. ".md"
end

local function read_raw(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

describe("util.read_line_from_file", function()
    it("returns the requested line when the file exists", function()
        local path = temp_md("line one\nline two\nline three\n")
        assert.are.equal("line two", util.read_line_from_file(path, 2))
    end)

    it("returns nil for an out-of-range line number", function()
        local path = temp_md("only one line\n")
        assert.is_nil(util.read_line_from_file(path, 5))
    end)

    it("returns nil (no error) when the source file does not exist", function()
        local path = missing_path()
        assert.has_no.errors(function()
            assert.is_nil(util.read_line_from_file(path, 1))
        end)
    end)
end)

describe("util.replace_line_in_file", function()
    it("does not error when the source file does not exist", function()
        local path = missing_path()
        assert.has_no.errors(function()
            util.replace_line_in_file(path, 1, "new content")
        end)
    end)
end)

describe("util.append_to_line", function()
    it("does not error when the source file does not exist", function()
        local path = missing_path()
        assert.has_no.errors(function()
            util.append_to_line(path, 1, " ::start [[2026-02-17]] 15:00")
        end)
    end)

    it("still appends to an existing file", function()
        local path = temp_md("alpha\nbeta\n")
        util.append_to_line(path, 1, " X")
        assert.are.equal("alpha X\nbeta\n", read_raw(path))
    end)
end)

describe("util.find_frontmatter_due_line", function()
    it("returns nil when the source file does not exist", function()
        local path = missing_path()
        assert.has_no.errors(function()
            assert.is_nil(util.find_frontmatter_due_line(path, "due"))
        end)
    end)
end)
