-- actions.lua — the verb / action layer (port of go/main.go's cmd* handlers).
--
-- This is a THIN composition over the already-tested mutate.lua + state.lua
-- primitives. It does NO direct file IO for writes and NO marker formatting of
-- its own — every byte that hits disk goes through mutate.append_to_line /
-- mutate.change_checkbox / mutate.remove_last_marker / mutate.insert_after_header
-- / mutate.append_to_file, and every marker comes from state.format_marker. The
-- ORDER of those calls is what determines the resulting bytes, so each verb
-- mirrors the operation order of its Go counterpart exactly (cited inline).
--
-- Determinism: every marker-producing verb takes an optional `now_epoch` (unix
-- seconds) — mirrors how Go threads `now time.Time` explicitly. Defaults to
-- os.time().
--
-- Buffer awareness (overview D9) is deliberately NOT here: these verbs are pure
-- file ops so their output stays byte-comparable to the Go binary. The
-- integration/keymaps layer owns the open-buffer safety concern.
--
-- `ctx` is the table produced by context.build_context (which starts from
-- parse.new_parse_context). Fields read here:
--   ctx.checkbox        = { open=, done=, irrelevant= }  (status -> literal)
--   ctx.marker_prefix   (default "::")
--   ctx.date_fmt, ctx.time_fmt   (raw strftime strings, for state.format_marker)
--   ctx.state_dir       (current_task directory; stop/complete/start)
--   ctx.date_pat_time, ctx.date_pat_notime  (inline-due matchers; defer only)
--
-- Return convention: every verb returns `ok:boolean, err_or_status:string|nil`.
-- For mutation-only verbs `err_or_status` is an error string on failure (nil on
-- success). For the state-based verbs (stop/complete/start) and the no-task
-- branches, the second value is a friendly STATUS string even on success — the
-- caller decides whether to surface it.

local mutate = require("taskbuffer.mutate")
local state = require("taskbuffer.state")

local M = {}

-- Expand a leading "~/" exactly like Go's expandHome (main.go:128). Only the
-- leading "~/" form is handled; anything else is returned verbatim.
local function expand_home(path)
    if type(path) == "string" and path:sub(1, 2) == "~/" then
        local home = vim.uv.os_homedir() or os.getenv("HOME")
        if home then
            return home .. path:sub(2)
        end
    end
    return path
end

-- Read line `lnum` of `path` for INSPECTION only (defer's ::original check +
-- inline-due extraction; unset's marker check). The actual writes go through
-- mutate.*, which re-read the file with full newline/CRLF fidelity, so this
-- read never influences the output bytes. Returns the line text, or nil if the
-- file cannot be read / the line is out of range.
local function read_line(path, lnum)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return nil
    end
    return lines[lnum]
end

-- Extract the inline due DATE string from a line. Mirrors Go's
-- ctx.dateRe.FindStringSubmatch(line)[1] (main.go:449) and parse.lua's
-- find_date_group: try the timed and timeless inline-due patterns and take the
-- leftmost group (the variant whose match ENDS earliest). Returns the date
-- string, or nil when no inline due date is present.
local function extract_inline_due_date(line, ctx)
    local st, et, dt = line:find(ctx.date_pat_time)
    local sn, en, dn = line:find(ctx.date_pat_notime)
    if st and sn then
        if et <= en then
            return dt
        end
        return dn
    elseif st then
        return dt
    elseif sn then
        return dn
    end
    return nil
end

-- cmdCompleteAt (main.go:536): append the ::complete marker FIRST, then flip the
-- checkbox open -> done. Order matters: the marker lands on the open line, then
-- the checkbox is rewritten in place.
---@param path string
---@param lnum integer
---@param ctx table
---@param now_epoch integer|nil
---@return boolean ok, string|nil err
function M.complete_at(path, lnum, ctx, now_epoch)
    now_epoch = now_epoch or os.time()
    local marker = state.format_marker("complete", now_epoch, ctx)
    local ok, err = mutate.append_to_line(path, lnum, marker)
    if not ok then
        return false, err
    end
    return mutate.check_off_task_with(path, lnum, ctx.checkbox.open, ctx.checkbox.done)
end

-- cmdDefer (main.go:421): if the line has no `<prefix>original` marker, copy the
-- current inline due date into a `<prefix>original [[DATE]]` marker (date only,
-- NO time, NO trailing space — note this is NOT a FormatMarker), then append the
-- `deferral` marker. Both appends go through mutate.append_to_line; two appends
-- are byte-identical to Go's single in-memory edit because append_to_line
-- right-trims then prepends " " (matching Go's `TrimRight + " " + marker`).
---@param path string
---@param lnum integer
---@param ctx table
---@param now_epoch integer|nil
---@return boolean ok, string|nil err
function M.defer(path, lnum, ctx, now_epoch)
    now_epoch = now_epoch or os.time()
    local prefix = ctx.marker_prefix or "::"

    local line = read_line(path, lnum)
    if line == nil then
        return false, "reading " .. path
    end

    -- Preserve the original due date as ::original, but only if one is not
    -- already recorded (main.go:447).
    if not line:find(prefix .. "original", 1, true) then
        local date = extract_inline_due_date(line, ctx)
        if date then
            -- append_to_line prepends the separating space, giving Go's
            -- " ::original [[DATE]]" (main.go:451).
            local ok, err = mutate.append_to_line(path, lnum, prefix .. "original [[" .. date .. "]]")
            if not ok then
                return false, err
            end
        end
    end

    local marker = state.format_marker("deferral", now_epoch, ctx)
    return mutate.append_to_line(path, lnum, marker)
end

-- cmdCheck (main.go:522): quick check-off, no marker. Flip open -> done.
---@param path string
---@param lnum integer
---@param ctx table
---@return boolean ok, string|nil err
function M.check(path, lnum, ctx)
    return mutate.check_off_task_with(path, lnum, ctx.checkbox.open, ctx.checkbox.done)
end

-- cmdIrrelevant (main.go:465): flip the checkbox open -> irrelevant FIRST, then
-- append the ::irrelevant marker. Order is the reverse of complete_at.
---@param path string
---@param lnum integer
---@param ctx table
---@param now_epoch integer|nil
---@return boolean ok, string|nil err
function M.irrelevant(path, lnum, ctx, now_epoch)
    now_epoch = now_epoch or os.time()
    local ok, err = mutate.change_checkbox(path, lnum, ctx.checkbox.open, ctx.checkbox.irrelevant)
    if not ok then
        return false, err
    end
    local marker = state.format_marker("irrelevant", now_epoch, ctx)
    return mutate.append_to_line(path, lnum, marker)
end

-- cmdUnset (main.go:487): undo an irrelevant marking. If the line carries a
-- `<prefix>irrelevant` marker, remove the LAST marker of that kind and restore
-- the checkbox irrelevant -> open. If no such marker is present it is a no-op
-- (ok, no write) — matches Go's fall-through return nil (main.go:518).
---@param path string
---@param lnum integer
---@param ctx table
---@return boolean ok, string|nil err
function M.unset(path, lnum, ctx)
    local prefix = ctx.marker_prefix or "::"
    local line = read_line(path, lnum)
    if line == nil then
        return false, "reading " .. path
    end
    if not line:find(prefix .. "irrelevant", 1, true) then
        return true -- no-op (main.go:518)
    end
    local ok, err = mutate.remove_last_marker(path, lnum, "irrelevant", ctx.date_fmt, ctx.time_fmt, ctx.marker_prefix)
    if not ok then
        return false, err
    end
    return mutate.change_checkbox(path, lnum, ctx.checkbox.irrelevant, ctx.checkbox.open)
end

-- cmdStopWithConfig (main.go:308): stop the currently-running task. No task
-- running -> friendly status, ok=true, no write. Otherwise append the ::stop
-- marker to the running task's file:line and clear the state file.
---@param ctx table
---@param now_epoch integer|nil
---@return boolean ok, string|nil err_or_status
function M.stop(ctx, now_epoch)
    now_epoch = now_epoch or os.time()
    local ct, err = state.read_current_task(ctx.state_dir)
    if err then
        return false, err
    end
    if not ct then
        return true, "No task running."
    end

    local marker = state.format_marker("stop", now_epoch, ctx)
    local ok, aerr = mutate.append_to_line(ct.filepath, ct.linenumber, marker)
    if not ok then
        return false, aerr
    end

    local cok, cerr = state.clear_current_task(ctx.state_dir)
    if not cok then
        return false, cerr
    end
    return true, "Stopped: " .. ct.name
end

-- cmdCompleteWithConfig (main.go:338): complete the currently-running task. Like
-- stop, but appends the ::complete marker, then flips the checkbox open -> done
-- (Go uses CheckOffTask; per the overview's canonical-checkbox decision we use
-- the configured open/done pair — byte-identical for default config), then
-- clears state. No task running -> friendly status, ok=true.
---@param ctx table
---@param now_epoch integer|nil
---@return boolean ok, string|nil err_or_status
function M.complete(ctx, now_epoch)
    now_epoch = now_epoch or os.time()
    local ct, err = state.read_current_task(ctx.state_dir)
    if err then
        return false, err
    end
    if not ct then
        return true, "No task running."
    end

    local marker = state.format_marker("complete", now_epoch, ctx)
    local ok, aerr = mutate.append_to_line(ct.filepath, ct.linenumber, marker)
    if not ok then
        return false, aerr
    end
    local dok, derr = mutate.check_off_task_with(ct.filepath, ct.linenumber, ctx.checkbox.open, ctx.checkbox.done)
    if not dok then
        return false, derr
    end

    local cok, cerr = state.clear_current_task(ctx.state_dir)
    if not cok then
        return false, cerr
    end
    return true, "Completed: " .. ct.name
end

-- start: the non-picker core of cmdDo (main.go:233-306). If a task is already
-- running, stop it first (appends its ::stop marker + clears state), then append
-- a ::start marker to the chosen task and record it as the current task. `body`
-- becomes the state file's display name (cosmetic; the marker writes are driven
-- by path+lnum, never the body).
---@param path string
---@param lnum integer
---@param body string
---@param ctx table
---@param now_epoch integer|nil
---@return boolean ok, string|nil err_or_status
function M.start(path, lnum, body, ctx, now_epoch)
    now_epoch = now_epoch or os.time()

    local existing, err = state.read_current_task(ctx.state_dir)
    if err then
        return false, err
    end
    if existing then
        local sok, serr = M.stop(ctx, now_epoch)
        if not sok then
            return false, serr
        end
    end

    local marker = state.format_marker("start", now_epoch, ctx)
    local ok, aerr = mutate.append_to_line(path, lnum, marker)
    if not ok then
        return false, aerr
    end

    local wok, werr = state.write_current_task(ctx.state_dir, {
        start_time = now_epoch,
        name = body,
        filepath = path,
        linenumber = lnum,
    })
    if not wok then
        return false, werr
    end
    return true, "Started: " .. body
end

-- cmdCreate (main.go:556): create a new task line. Resolve the target file
-- (expanding a leading "~/"), ensure its parent directory exists, then either
-- insert below `header` or append to the file end.
---@param body string
---@param target_file string
---@param header string|nil
---@param ctx table
---@return boolean ok, string|nil err
function M.create(body, target_file, header, ctx)
    if not body or body == "" then
        return false, "create: empty task body"
    end
    if not target_file or target_file == "" then
        return false, "create: no target file specified"
    end

    local file = expand_home(target_file)

    -- Ensure parent directory exists (main.go:584-587).
    local dir = vim.fn.fnamemodify(file, ":h")
    if dir and dir ~= "" and dir ~= "." then
        vim.fn.mkdir(dir, "p")
    end

    local task_line = ctx.checkbox.open .. " " .. body
    if header and header ~= "" then
        return mutate.insert_after_header(file, header, task_line)
    end
    return mutate.append_to_file(file, task_line)
end

return M
