-- Ported from go/mutate_test.go and go/mutate_new_test.go (the file-line
-- primitives only; the cmd* verb handlers belong to the actions layer).
--
-- Fixtures are written under vim.fn.tempname() (OS tempdir), never the worktree.
-- Assertions are byte-exact: the Go `want` strings transfer verbatim.

local mutate = require("taskbuffer.mutate")

-- Write content bytes to a fresh temp .md file, return its path.
local function temp_md(content)
    local path = vim.fn.tempname() .. ".md"
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
    return path
end

-- A temp path that does NOT yet exist (for create-file cases).
local function temp_path()
    return vim.fn.tempname() .. ".md"
end

-- Read the whole file back as raw bytes.
local function read_raw(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

-- Mirror of go/mutate_test.go:splitLines — split on "\n", dropping the trailing
-- empty element produced by a final newline.
local function lines_of(content)
    local out = {}
    local start = 1
    for i = 1, #content do
        if content:sub(i, i) == "\n" then
            out[#out + 1] = content:sub(start, i - 1)
            start = i + 1
        end
    end
    if start <= #content then
        out[#out + 1] = content:sub(start)
    end
    return out
end

local function read_lines(path)
    return lines_of(read_raw(path))
end

describe("mutate.append_to_line", function()
    it("appends text, keeping the marker's trailing space, others unchanged", function()
        local path = temp_md("line one\nline two\nline three\n")
        local ok = mutate.append_to_line(path, 2, "::start [[2026-02-17]] 15:00 ")
        assert.is_true(ok)
        local lines = read_lines(path)
        assert.are.equal("line two ::start [[2026-02-17]] 15:00 ", lines[2])
        assert.are.equal("line one", lines[1])
        assert.are.equal("line three", lines[3])
    end)

    it("errors for an out-of-range line number, no write", function()
        local path = temp_md("only one line\n")
        local ok, err = mutate.append_to_line(path, 5, "text")
        assert.is_false(ok)
        assert.is_truthy(err)
        assert.are.equal("only one line\n", read_raw(path))
    end)
end)

describe("mutate.check_off_task / change_checkbox", function()
    it("checks off the target task, leaving sibling lines untouched", function()
        local path = temp_md("# Tasks\n- [ ] Buy groceries (@[[2026-02-17]])\n- [ ] Other task\n")
        local ok = mutate.check_off_task(path, 2)
        assert.is_true(ok)
        local lines = read_lines(path)
        assert.are.equal("- [x] Buy groceries (@[[2026-02-17]])", lines[2])
        assert.are.equal("- [ ] Other task", lines[3])
    end)

    it("preserves indentation (positional replace)", function()
        local path = temp_md("\t- [ ] Indented task (@[[2026-02-17]])\n")
        local ok = mutate.check_off_task(path, 1)
        assert.is_true(ok)
        local lines = read_lines(path)
        assert.are.equal("\t- [x] Indented task (@[[2026-02-17]])", lines[1])
    end)

    it("change_checkbox replaces only the first occurrence on the line", function()
        local path = temp_md("- [ ] Open task\n- [x] Done task\n")
        local ok = mutate.change_checkbox(path, 1, "- [ ]", "- [-]")
        assert.is_true(ok)
        local lines = read_lines(path)
        assert.are.equal("- [-] Open task", lines[1])
        assert.are.equal("- [x] Done task", lines[2])
    end)

    it("errors on empty from/to checkbox strings", function()
        local path = temp_md("- [ ] Task\n")
        local ok1, err1 = mutate.change_checkbox(path, 1, "", "- [x]")
        assert.is_false(ok1)
        assert.is_truthy(err1)
        local ok2, err2 = mutate.change_checkbox(path, 1, "- [ ]", "")
        assert.is_false(ok2)
        assert.is_truthy(err2)
    end)

    it("check_off_task_with uses the supplied checkbox pair", function()
        local path = temp_md("- [ ] Task\n")
        local ok = mutate.check_off_task_with(path, 1, "- [ ]", "- [-]")
        assert.is_true(ok)
        assert.are.equal("- [-] Task", read_lines(path)[1])
    end)
end)

describe("mutate.remove_last_marker", function()
    it("removes the marker, preserving the inline due date", function()
        local path = temp_md("- [-] Task (@[[2026-02-17]]) ::irrelevant [[2026-02-18]] 10:00\n")
        local ok = mutate.remove_last_marker(path, 1, "irrelevant")
        assert.is_true(ok)
        local line = read_lines(path)[1]
        assert.are.equal("- [-] Task (@[[2026-02-17]])", line)
    end)

    it("removes only the LAST of multiple markers", function()
        local path = temp_md(
            "- [-] Task ::irrelevant [[2026-02-17]] 09:00 ::irrelevant [[2026-02-18]] 10:00\n"
        )
        local ok = mutate.remove_last_marker(path, 1, "irrelevant")
        assert.is_true(ok)
        local line = read_lines(path)[1]
        assert.are.equal("- [-] Task ::irrelevant [[2026-02-17]] 09:00", line)
    end)

    it("is a no-op (ok) when no marker of that kind is present", function()
        local path = temp_md("- [ ] Task with no marker\n")
        local ok = mutate.remove_last_marker(path, 1, "irrelevant")
        assert.is_true(ok)
        assert.are.equal("- [ ] Task with no marker\n", read_raw(path))
    end)

    it("removes a marker with no time component", function()
        local path = temp_md("- [-] Task ::deferral [[2026-02-18]]\n")
        local ok = mutate.remove_last_marker(path, 1, "deferral")
        assert.is_true(ok)
        assert.are.equal("- [-] Task", read_lines(path)[1])
    end)

    it("errors for an out-of-range line number", function()
        local path = temp_md("- [ ] Task\n")
        local ok, err = mutate.remove_last_marker(path, 9, "irrelevant")
        assert.is_false(ok)
        assert.is_truthy(err)
    end)
end)

describe("mutate.insert_after_header", function()
    it("inserts the text on the line after a matching header", function()
        local path = temp_md("# Tasks\n- [ ] Existing task\n\n# Other\n")
        local ok = mutate.insert_after_header(path, "# Tasks", "- [ ] New task")
        assert.is_true(ok)
        local lines = read_lines(path)
        assert.are.equal("# Tasks", lines[1])
        assert.are.equal("- [ ] New task", lines[2])
        assert.are.equal("- [ ] Existing task", lines[3])
    end)

    it("creates the file when it does not exist", function()
        local path = temp_path()
        local ok = mutate.insert_after_header(path, "## Tasks", "- [ ] First task")
        assert.is_true(ok)
        assert.are.equal("## Tasks\n- [ ] First task\n", read_raw(path))
    end)

    it("appends header + text when the header is not found", function()
        local path = temp_md("# Notes\nsome text\n")
        local ok = mutate.insert_after_header(path, "## Missing", "- [ ] X")
        assert.is_true(ok)
        assert.are.equal("# Notes\nsome text\n\n## Missing\n- [ ] X\n", read_raw(path))
    end)
end)

describe("mutate.append_to_file", function()
    it("appends a line, preserving the existing trailing newline", function()
        local path = temp_md("# Tasks\n- [ ] Existing\n")
        local ok = mutate.append_to_file(path, "- [ ] Appended task")
        assert.is_true(ok)
        assert.are.equal("# Tasks\n- [ ] Existing\n- [ ] Appended task\n", read_raw(path))
    end)

    it("creates the file when it does not exist", function()
        local path = temp_path()
        local ok = mutate.append_to_file(path, "- [ ] Brand new task")
        assert.is_true(ok)
        assert.are.equal("- [ ] Brand new task\n", read_raw(path))
    end)
end)

-- Decision D10: preserve the file's trailing-newline / CRLF state exactly,
-- mirroring Go's strings.Split/Join (never force-append a "\n").
describe("mutate newline + CRLF fidelity (D10)", function()
    it("does NOT add a trailing newline to a file that had none", function()
        local path = temp_md("line one\nline two") -- no final newline
        local ok = mutate.append_to_line(path, 2, "X")
        assert.is_true(ok)
        assert.are.equal("line one\nline two X", read_raw(path))
    end)

    it("keeps the trailing newline of a file that had one", function()
        local path = temp_md("line one\nline two\n")
        local ok = mutate.append_to_line(path, 2, "X")
        assert.is_true(ok)
        assert.are.equal("line one\nline two X\n", read_raw(path))
    end)

    it("append_to_file adds the separator newline for a file lacking one", function()
        local path = temp_md("no newline at end") -- no final newline
        local ok = mutate.append_to_file(path, "appended")
        assert.is_true(ok)
        assert.are.equal("no newline at end\nappended\n", read_raw(path))
    end)

    it("CRLF: the marker lands after the \\r (Go parity)", function()
        local path = temp_md("a\r\nb\r\n")
        local ok = mutate.append_to_line(path, 2, "::m")
        assert.is_true(ok)
        assert.are.equal("a\r\nb\r ::m\n", read_raw(path))
    end)
end)
