-- Ported from go/state_test.go, plus byte-format and malformed-input pins.
--
-- The state directory is an explicit temp dir per test (the Go tests use
-- t.Setenv("HOME", ...); these primitives take state_dir directly). The
-- current_task file format must be BYTE-IDENTICAL to Go (state.go:83).

local state = require("taskbuffer.state")

-- A fresh, not-yet-existing temp dir to act as the state directory.
local function temp_dir()
    return vim.fn.tempname()
end

local function read_raw(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

local function write_raw(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

describe("state read/write/clear", function()
    it("round-trips a current task through write then read", function()
        local dir = temp_dir()
        local ct = {
            start_time = 1739800000,
            name = "Buy groceries",
            filepath = "/notes/daily/2026-02-17.md",
            linenumber = 5,
        }
        assert.is_true(state.write_current_task(dir, ct))

        local got, err = state.read_current_task(dir)
        assert.is_nil(err)
        assert.is_truthy(got)
        assert.are.equal(1739800000, got.start_time)
        assert.are.equal("Buy groceries", got.name)
        assert.are.equal("/notes/daily/2026-02-17.md", got.filepath)
        assert.are.equal(5, got.linenumber)
    end)

    it("write produces the byte-exact TSV line with a trailing newline", function()
        local dir = temp_dir()
        assert.is_true(state.write_current_task(dir, {
            start_time = 1739800000,
            name = "Buy groceries",
            filepath = "/notes/daily/2026-02-17.md",
            linenumber = 5,
        }))
        assert.are.equal("1739800000\tBuy groceries\t/notes/daily/2026-02-17.md\t5\n", read_raw(state.state_path(dir)))
    end)

    it("returns nil,nil when the state file is missing", function()
        local got, err = state.read_current_task(temp_dir())
        assert.is_nil(got)
        assert.is_nil(err)
    end)

    it("clears an existing state file", function()
        local dir = temp_dir()
        assert.is_true(state.write_current_task(dir, {
            start_time = 1,
            name = "test",
            filepath = "/a.md",
            linenumber = 1,
        }))
        assert.is_true(state.clear_current_task(dir))
        assert.is_nil(vim.uv.fs_stat(state.state_path(dir)))
    end)

    it("clear is a no-op (ok) when the state file is missing", function()
        local ok = state.clear_current_task(temp_dir())
        assert.is_true(ok)
    end)
end)

describe("state read malformed input", function()
    it("errors when fewer than 4 tab-separated fields", function()
        local dir = temp_dir()
        vim.fn.mkdir(dir, "p")
        write_raw(state.state_path(dir), "123\tonly\ttwo\n")
        local got, err = state.read_current_task(dir)
        assert.is_nil(got)
        assert.is_truthy(err)
    end)

    it("errors on a non-numeric timestamp", function()
        local dir = temp_dir()
        vim.fn.mkdir(dir, "p")
        write_raw(state.state_path(dir), "notnum\tname\t/a.md\t5\n")
        local got, err = state.read_current_task(dir)
        assert.is_nil(got)
        assert.is_truthy(err)
    end)

    it("errors on a non-numeric line number", function()
        local dir = temp_dir()
        vim.fn.mkdir(dir, "p")
        write_raw(state.state_path(dir), "123\tname\t/a.md\tnope\n")
        local got, err = state.read_current_task(dir)
        assert.is_nil(got)
        assert.is_truthy(err)
    end)
end)

describe("state.format_marker", function()
    -- An epoch whose local time is 2026-02-17 15:00 (built the same way it is
    -- displayed, so the round-trip is local-tz-independent).
    local epoch = os.time({ year = 2026, month = 2, day = 17, hour = 15, min = 0, sec = 0 })
    local ctx = { date_fmt = "%Y-%m-%d", time_fmt = "%H:%M", marker_prefix = "::" }

    it("produces the canonical '::kind [[DATE]] TIME ' with trailing space", function()
        assert.are.equal("::start [[2026-02-17]] 15:00 ", state.format_marker("start", epoch, ctx))
    end)

    it("honors a custom marker_prefix (D8)", function()
        local custom = { date_fmt = "%Y-%m-%d", time_fmt = "%H:%M", marker_prefix = ">>" }
        assert.are.equal(">>deferral [[2026-02-17]] 15:00 ", state.format_marker("deferral", epoch, custom))
    end)

    it("defaults the prefix to '::' when ctx omits it", function()
        local noprefix = { date_fmt = "%Y-%m-%d", time_fmt = "%H:%M" }
        assert.are.equal("::stop [[2026-02-17]] 15:00 ", state.format_marker("stop", epoch, noprefix))
    end)
end)
