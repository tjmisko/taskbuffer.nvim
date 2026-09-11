-- Drive another Neovim through its normal input/event loop. Waiting inside the
-- editor under test can hide TextChanged and redraw bugs, so waits live here.
local M = {}

function M.new()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/vault", "p")
    root = vim.uv.fs_realpath(root)
    local editor = { root = root, path = root .. "/vault/tasks.md" }
    vim.fn.writefile({ "- [ ] Example task (@[[2026-02-17]])", "Saved paragraph" }, editor.path)
    editor.job = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, {
        rpc = true,
        env = {
            XDG_CONFIG_HOME = root .. "/config",
            XDG_DATA_HOME = root .. "/data",
            XDG_STATE_HOME = root .. "/state",
            XDG_CACHE_HOME = root .. "/cache",
            NVIM_LOG_FILE = root .. "/nvim.log",
        },
    })
    assert(editor.job > 0, "could not start test editor")

    function editor.lua(code, ...)
        return vim.rpcrequest(editor.job, "nvim_exec_lua", code, { ... })
    end

    function editor.command(command)
        return vim.rpcrequest(editor.job, "nvim_command", command)
    end

    function editor.input(keys)
        return vim.rpcrequest(editor.job, "nvim_input", keys)
    end

    function editor.wait(code, reason, ...)
        local args = { ... }
        local ready = vim.wait(3000, function()
            return editor.lua(code, unpack(args)) == true
        end, 10)
        if not ready then
            error(reason .. ": " .. vim.inspect(editor.lua([[
                return { lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
                    warning = vim.v.warningmsg, error = vim.v.errmsg, notifications = _G.test_warnings }
            ]])))
        end
    end

    function editor.lines()
        return editor.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
    end

    function editor.no_warnings()
        local messages = editor.lua([[
            return { warning = vim.v.warningmsg, error = vim.v.errmsg,
                notifications = _G.test_warnings, history = vim.api.nvim_exec2('messages', { output = true }).output }
        ]])
        assert(messages.warning == "", messages.warning)
        assert(messages.error == "", messages.error)
        assert(#messages.notifications == 0, vim.inspect(messages.notifications))
        assert(not messages.history:match("W%d+:"), messages.history)
    end

    function editor.close()
        pcall(editor.command, "qa!")
        if vim.fn.jobwait({ editor.job }, 1000)[1] == -1 then
            vim.fn.jobstop(editor.job)
            vim.fn.jobwait({ editor.job }, 1000)
        end
        vim.fn.delete(root, "rf")
    end

    local ok, err = pcall(
        editor.lua,
        [[
        local project, root, obsidian = ...
        vim.opt.rtp:prepend(project)
        vim.g.mapleader = ' '
        vim.o.hidden = true
        vim.cmd('filetype plugin on')
        _G.test_warnings = {}
        local notify = vim.notify
        vim.notify = function(message, level, opts)
            if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then
                table.insert(_G.test_warnings, message)
            end
            notify(message, level, opts)
        end
        require('taskbuffer').setup({ sources = { root .. '/vault' }, tmpdir = root, state_dir = root .. '/state' })
        vim.cmd('runtime plugin/taskbuffer.lua')
        -- Observe the public event contract without invoking it ourselves.
        _G.test_changes = {}
        vim.api.nvim_create_autocmd('TextChanged', {
            callback = function(event)
                table.insert(_G.test_changes, vim.api.nvim_buf_get_lines(event.buf, 0, -1, false))
            end,
        })
        if obsidian ~= '' then
            vim.opt.rtp:append(obsidian)
            local ui = require('obsidian.config.default').ui
            ui.update_debounce = 10
            ui.ignore_conceal_warn = true
            -- Load only its renderer, against this temporary workspace.
            require('obsidian.ui').setup({ name = 'test', root = root .. '/vault' }, ui)
        end
    ]],
        vim.env.TASKBUFFER_TEST_PROJECT or vim.fn.getcwd(),
        root,
        vim.env.TASKBUFFER_TEST_OBSIDIAN or ""
    )
    if not ok then
        editor.close()
        error(err)
    end
    return editor
end

return M
