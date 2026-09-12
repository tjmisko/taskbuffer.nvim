local M = {}
local overlay = require("keys")
local sequence = require("sequence")
local config, active, paused, generation, take = nil, false, false, 0, 0
local state, checks, warnings = {}, {}, {}

local function recording_ack()
    local ok, ack = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(config.control .. ".obs.json"), "\n"))
    end)
    return ok and ack.run_id == state.run_id and ack or nil
end

local function publish(status)
    state.status, state.heartbeat = status or state.status, os.time()
    local temporary = config.control .. ".tmp"
    vim.fn.writefile({ vim.json.encode(state) }, temporary)
    assert((vim.uv or vim.loop).fs_rename(temporary, config.control))
end

local function finish(status, err)
    active, paused = false, false
    generation = generation + 1
    publish(status)
    if err then
        overlay.scene("Stopped: " .. err:gsub("\n.*", ""))
    end
    vim.fn.writefile({
        vim.json.encode({
            status = status,
            error = err,
            takes = take,
            checks = checks,
            warnings = warnings,
            keys = overlay.log,
        }),
    }, config.root .. "/result.json")
    if config.check then
        if status == "complete" and take < 2 then
            vim.defer_fn(M.start, 100)
        else
            vim.schedule(function()
                vim.cmd(status == "complete" and "qa!" or "cquit 1")
            end)
        end
    end
end

-- Resume only from a scheduled callback: the editor must process input, autocmds,
-- Telescope, and async scan completions between every step.
function M.sleep(ms)
    coroutine.yield(ms)
end

function M.hold(ms)
    M.sleep(config.check and 15 or ms)
end

function M.wait(predicate, description)
    for _ = 1, 250 do
        if predicate() then
            return
        end
        M.sleep(20)
    end
    error("Timed out: " .. description)
end

function M.expect(value, description)
    assert(value, description)
    checks[#checks + 1] = description
end

function M.keys(input)
    local pos = 1
    while pos <= #input do
        local token = input:sub(pos):match("^<[^>]+>") or vim.fn.strcharpart(input:sub(pos), 0, 1)
        local accepted = vim.api.nvim_input(token)
        assert(accepted == #token, "input queue rejected " .. token)
        M.sleep(config.check and 10 or 65)
        pos = pos + #token
    end
    M.sleep(config.check and 30 or 180)
end

-- Deliver mapping chords together: Neovim can wait for a partial mapping without
-- running scheduled Lua callbacks. Text is still typed character by character.
function M.press(chord)
    assert(vim.api.nvim_input(chord) == #chord, "input queue rejected " .. chord)
    M.sleep(config.check and 30 or 250)
end

M.scene = overlay.scene
M.line = vim.api.nvim_get_current_line
function M.text()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end
function M.disk(name)
    return table.concat(vim.fn.readfile(config.root .. "/vault/" .. name), "\n")
end
function M.tasks(text)
    M.wait(function()
        return vim.bo.filetype == "taskfile"
            and not require("taskbuffer.buffer").get_refreshing()
            and M.text():find(text, 1, true)
    end, "task list: " .. text)
end

local function reset()
    require("taskbuffer.buffer").cancel_refresh()
    -- This editor belongs exclusively to the disposable demo.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= overlay.win and vim.api.nvim_win_get_config(win).relative ~= "" then
            vim.api.nvim_win_close(win, true)
        end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if buf ~= overlay.buf then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
    for name, lines in pairs(sequence.fixtures()) do
        vim.fn.writefile(lines, config.root .. "/vault/" .. name)
    end
    require("taskbuffer.list").invalidate()
    vim.cmd.edit(vim.fn.fnameescape(config.root .. "/vault/Studio.md"))
    vim.cmd("normal! gg")
    vim.cmd("clearjumps")
    vim.cmd("nohlsearch")
    vim.v.errmsg = ""
end

function M.start()
    if active then
        return
    end
    active, paused, generation, take = true, false, generation + 1, take + 1
    local id = generation
    state = { run_id = tostring((vim.uv or vim.loop).hrtime()), record = config.record }
    publish("preparing")
    local thread = coroutine.create(function()
        -- Escape insert mode before resetting an interrupted take.
        M.keys("<Esc>")
        reset()
        if config.record then
            overlay.scene("Waiting for OBS…")
            publish("record-request")
            local started = false
            for _ = 1, 300 do
                local ack = recording_ack()
                if ack then
                    assert(not ack.error, ack.error)
                    if ack.status == "recording" then
                        started = true
                        break
                    end
                end
                M.sleep(100)
            end
            assert(started, "OBS did not respond; load scripts/demo/obs.lua and select the control file")
        end
        publish("playing")
        for remaining = 3, 1, -1 do
            overlay.scene("Starting in " .. remaining .. "…")
            M.hold(1000)
        end
        sequence.play(M)
        M.expect(#warnings == 0, "no plugin warning notifications")
        M.expect(vim.v.errmsg == "", "no editor errors")
        local messages = vim.api.nvim_exec2("messages", { output = true }).output
        M.expect(not messages:match("W10:") and not messages:match("W13:"), "no readonly or file-change warnings")
        M.expect(#overlay.log > 50, "screencast received real typed keys")
    end)
    local function resume()
        if id ~= generation then
            return
        end
        if paused then
            vim.defer_fn(resume, 100)
            return
        end
        local ok, delay = coroutine.resume(thread)
        if not ok then
            finish("error", tostring(delay))
            return
        end
        if coroutine.status(thread) == "dead" then
            finish("complete")
            return
        end
        vim.defer_fn(resume, delay)
    end
    vim.schedule(resume)
end

function M.setup(opts)
    config = opts
    overlay.setup()
    local notify = vim.notify
    vim.notify = function(message, level, options)
        if level and level >= vim.log.levels.WARN then
            warnings[#warnings + 1] = tostring(message)
        end
        return notify(message, level, options)
    end
    reset()
    overlay.scene("taskbuffer.nvim   •   F5 starts a fresh take")
    for _, mode in ipairs({ "n", "i", "v", "c" }) do
        vim.keymap.set(mode, "<F5>", M.start)
        vim.keymap.set(mode, "<F6>", function()
            if not active then
                return
            end
            paused = not paused
            overlay.title = paused and "Paused — F6 resumes" or "Continuing…"
            overlay.render()
        end)
        vim.keymap.set(mode, "<F8>", function()
            if active then
                finish("aborted", "F5 starts a fresh take")
            end
        end)
    end
    local timer = (vim.uv or vim.loop).new_timer()
    timer:start(
        1000,
        1000,
        vim.schedule_wrap(function()
            publish()
            if active and config.record and state.status == "playing" then
                local ack = recording_ack()
                if ack and ack.error then
                    finish("error", ack.error)
                end
            end
        end)
    )
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            timer:stop()
            timer:close()
            publish("closed")
        end,
    })
    if config.check then
        M.start()
    end
end

return M
