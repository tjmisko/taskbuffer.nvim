-- Deterministic byte-exact tests for the verb layer (actions.lua), the Lua port
-- of go/main.go's cmd* handlers.
--
-- Every marker-producing verb is driven with a FIXED now_epoch so the golden
-- strings never depend on wall-clock. The epoch is built with os.time{...} and
-- the markers re-display it with os.date(...) — both LOCAL — so the round-trip
-- ("2026-02-17" / "15:00") is timezone-independent.
--
-- Each marker is state.format_marker output: `<prefix>kind [[DATE]] TIME ` with
-- a TRAILING space. The expected file bytes are hand-derived from the Go verb's
-- operation ORDER (append-vs-checkbox first) since that order determines layout.
--
-- Fixtures live under vim.fn.tempname() (OS tempdir), never the worktree.

local actions = require("taskbuffer.actions")
local parse = require("taskbuffer.parse")
local state = require("taskbuffer.state")

-- Fixed clock: local time 2026-02-17 15:00:00 -> "2026-02-17" / "15:00".
local NOW = os.time({ year = 2026, month = 2, day = 17, hour = 15, min = 0, sec = 0 })

-- Build a ctx with the same fields context.build_context produces, but assembled
-- directly here for a self-contained deterministic test. parse.new_parse_context
-- supplies checkbox/marker_prefix/date_pat_*; date_fmt/time_fmt/state_dir are the
-- context-layer additions that state.format_marker / the state verbs read.
local function make_ctx(state_dir)
    local ctx = parse.new_parse_context({})
    ctx.date_fmt = "%Y-%m-%d"
    ctx.time_fmt = "%H:%M"
    ctx.state_dir = state_dir
    return ctx
end

-- Write content bytes to a fresh temp .md file, return its path.
local function temp_md(content)
    local path = vim.fn.tempname() .. ".md"
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
    return path
end

-- A fresh, not-yet-existing temp dir (state dir / create targets).
local function temp_dir()
    return vim.fn.tempname()
end

local function read_raw(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

describe("actions.complete_at", function()
    it("appends the complete marker THEN checks off (open -> done)", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [ ] Task body\n")
        local ok = actions.complete_at(path, 1, ctx, NOW)
        assert.is_true(ok)
        assert.are.equal("- [x] Task body ::complete [[2026-02-17]] 15:00 \n", read_raw(path))
    end)
end)

describe("actions.defer", function()
    it("copies the inline due date as ::original, then appends ::deferral", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [ ] Deferred task (@[[2026-02-17]])\n")
        local ok = actions.defer(path, 1, ctx, NOW)
        assert.is_true(ok)
        assert.are.equal(
            "- [ ] Deferred task (@[[2026-02-17]]) ::original [[2026-02-17]] ::deferral [[2026-02-17]] 15:00 \n",
            read_raw(path)
        )
    end)

    it("extracts the date from a TIMED inline due, keeping the time intact", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [ ] Meeting (@[[2026-02-17]] 16:00)\n")
        local ok = actions.defer(path, 1, ctx, NOW)
        assert.is_true(ok)
        assert.are.equal(
            "- [ ] Meeting (@[[2026-02-17]] 16:00) ::original [[2026-02-17]] ::deferral [[2026-02-17]] 15:00 \n",
            read_raw(path)
        )
    end)

    it("preserves an existing ::original (does not add a second one)", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [ ] Task (@[[2026-02-20]]) ::original [[2026-02-17]]\n")
        local ok = actions.defer(path, 1, ctx, NOW)
        assert.is_true(ok)
        local out = read_raw(path)
        assert.are.equal(
            "- [ ] Task (@[[2026-02-20]]) ::original [[2026-02-17]] ::deferral [[2026-02-17]] 15:00 \n",
            out
        )
        local _, count = out:gsub("::original", "")
        assert.are.equal(1, count)
    end)

    it("appends only ::deferral when the line has no inline due date", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [ ] Task with no date\n")
        local ok = actions.defer(path, 1, ctx, NOW)
        assert.is_true(ok)
        assert.are.equal("- [ ] Task with no date ::deferral [[2026-02-17]] 15:00 \n", read_raw(path))
    end)
end)

describe("actions.check", function()
    it("flips the checkbox open -> done with no marker", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [ ] Quick task\n")
        local ok = actions.check(path, 1, ctx)
        assert.is_true(ok)
        assert.are.equal("- [x] Quick task\n", read_raw(path))
    end)
end)

describe("actions.irrelevant", function()
    it("flips the checkbox open -> irrelevant THEN appends the marker", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [ ] Irrelevant task (@[[2026-02-17]])\n")
        local ok = actions.irrelevant(path, 1, ctx, NOW)
        assert.is_true(ok)
        assert.are.equal("- [-] Irrelevant task (@[[2026-02-17]]) ::irrelevant [[2026-02-17]] 15:00 \n", read_raw(path))
    end)
end)

describe("actions.unset", function()
    it("removes the last marker and restores the checkbox irrelevant -> open", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [-] Task (@[[2026-02-17]]) ::irrelevant [[2026-02-18]] 10:00\n")
        local ok = actions.unset(path, 1, ctx)
        assert.is_true(ok)
        assert.are.equal("- [ ] Task (@[[2026-02-17]])\n", read_raw(path))
    end)

    it("round-trips irrelevant -> unset back to the original open line", function()
        local ctx = make_ctx(temp_dir())
        local original = "- [ ] Roundtrip task (@[[2026-02-17]])\n"
        local path = temp_md(original)
        assert.is_true(actions.irrelevant(path, 1, ctx, NOW))
        assert.is_true(actions.unset(path, 1, ctx))
        assert.are.equal(original, read_raw(path))
    end)

    it("is a no-op (ok, no write) when there is no irrelevant marker", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("- [ ] Plain task\n")
        local ok = actions.unset(path, 1, ctx)
        assert.is_true(ok)
        assert.are.equal("- [ ] Plain task\n", read_raw(path))
    end)
end)

describe("actions.stop", function()
    it("appends the stop marker to the running task and clears state", function()
        local dir = temp_dir()
        local ctx = make_ctx(dir)
        local path = temp_md("- [ ] Running task\n")
        assert.is_true(state.write_current_task(dir, {
            start_time = NOW,
            name = "Running task",
            filepath = path,
            linenumber = 1,
        }))

        local ok, status = actions.stop(ctx, NOW)
        assert.is_true(ok)
        assert.are.equal("Stopped: Running task", status)
        assert.are.equal("- [ ] Running task ::stop [[2026-02-17]] 15:00 \n", read_raw(path))
        assert.is_nil(vim.uv.fs_stat(state.state_path(dir)))
    end)

    it("is a friendly no-op when nothing is running", function()
        local ctx = make_ctx(temp_dir())
        local ok, status = actions.stop(ctx, NOW)
        assert.is_true(ok)
        assert.are.equal("No task running.", status)
    end)
end)

describe("actions.complete", function()
    it("appends the complete marker, checks off, and clears state", function()
        local dir = temp_dir()
        local ctx = make_ctx(dir)
        local path = temp_md("- [ ] Finish me\n")
        assert.is_true(state.write_current_task(dir, {
            start_time = NOW,
            name = "Finish me",
            filepath = path,
            linenumber = 1,
        }))

        local ok, status = actions.complete(ctx, NOW)
        assert.is_true(ok)
        assert.are.equal("Completed: Finish me", status)
        assert.are.equal("- [x] Finish me ::complete [[2026-02-17]] 15:00 \n", read_raw(path))
        assert.is_nil(vim.uv.fs_stat(state.state_path(dir)))
    end)

    it("is a friendly no-op when nothing is running", function()
        local ctx = make_ctx(temp_dir())
        local ok, status = actions.complete(ctx, NOW)
        assert.is_true(ok)
        assert.are.equal("No task running.", status)
    end)
end)

describe("actions.start", function()
    it("appends the start marker and writes the current_task state", function()
        local dir = temp_dir()
        local ctx = make_ctx(dir)
        local path = temp_md("- [ ] New task\n")

        local ok, status = actions.start(path, 1, "New task", ctx, NOW)
        assert.is_true(ok)
        assert.are.equal("Started: New task", status)
        assert.are.equal("- [ ] New task ::start [[2026-02-17]] 15:00 \n", read_raw(path))

        local expected_state = string.format("%d\tNew task\t%s\t1\n", NOW, path)
        assert.are.equal(expected_state, read_raw(state.state_path(dir)))
    end)

    it("stops the running task first, then starts the new one", function()
        local dir = temp_dir()
        local ctx = make_ctx(dir)
        local path_a = temp_md("- [ ] Task A\n")
        local path_b = temp_md("- [ ] Task B\n")
        assert.is_true(state.write_current_task(dir, {
            start_time = NOW,
            name = "Task A",
            filepath = path_a,
            linenumber = 1,
        }))

        local ok = actions.start(path_b, 1, "Task B", ctx, NOW)
        assert.is_true(ok)
        -- Old task stopped...
        assert.are.equal("- [ ] Task A ::stop [[2026-02-17]] 15:00 \n", read_raw(path_a))
        -- ...new task started...
        assert.are.equal("- [ ] Task B ::start [[2026-02-17]] 15:00 \n", read_raw(path_b))
        -- ...and state now points at the new task.
        assert.are.equal(string.format("%d\tTask B\t%s\t1\n", NOW, path_b), read_raw(state.state_path(dir)))
    end)
end)

describe("actions.create", function()
    it("appends the open task line to the file end when no header is given", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("# Inbox\n")
        local ok = actions.create("Test task body", path, nil, ctx)
        assert.is_true(ok)
        assert.are.equal("# Inbox\n- [ ] Test task body\n", read_raw(path))
    end)

    it("inserts the open task line directly below the given header", function()
        local ctx = make_ctx(temp_dir())
        local path = temp_md("# Notes\nSome text\n\n## Tasks\n- [ ] Existing task\n\n## Other\n")
        local ok = actions.create("New task here", path, "## Tasks", ctx)
        assert.is_true(ok)
        assert.are.equal(
            "# Notes\nSome text\n\n## Tasks\n- [ ] New task here\n- [ ] Existing task\n\n## Other\n",
            read_raw(path)
        )
    end)

    it("errors on an empty body", function()
        local ctx = make_ctx(temp_dir())
        local ok, err = actions.create("", temp_md(""), nil, ctx)
        assert.is_false(ok)
        assert.is_truthy(err)
    end)
end)
