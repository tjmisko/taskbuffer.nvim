local M = { history = {}, log = {}, title = "" }
local ns = vim.api.nvim_create_namespace("taskbuffer-demo-keys")
local shortcuts = {
    ["<C-^>"] = "Ctrl-6",
    ["<C-O>"] = "Ctrl-o",
    ["<C-T>"] = "Ctrl-t",
    ["<C-R>"] = "Ctrl-r",
    ["<M-Left>"] = "Alt+Left",
    ["<M-Right>"] = "Alt+Right",
}

function M.render()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        return
    end
    local width = math.max(20, math.min(60, vim.o.columns - 6))
    local opts = {
        relative = "editor",
        row = math.max(0, vim.o.lines - 8),
        col = math.max(0, vim.o.columns - width - 3),
        width = width,
        height = 3,
        style = "minimal",
        focusable = false,
        zindex = 250,
        border = "rounded",
    }
    if not M.win or not vim.api.nvim_win_is_valid(M.win) then
        M.win = vim.api.nvim_open_win(M.buf, false, opts)
        vim.wo[M.win].winhighlight = "Normal:TaskbufferDemo,FloatBorder:TaskbufferDemo"
    else
        vim.api.nvim_win_set_config(M.win, opts)
    end
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, {
        " " .. M.title,
        " " .. table.concat(M.history, " "),
        " F5 replay   F6 pause/resume   F8 stop",
    })
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(M.buf, ns, 0, 0, { end_row = 1, hl_group = "TaskbufferDemoTitle" })
end

function M.scene(title)
    M.title, M.history = title, {}
    M.last_text = false
    M.render()
end

-- Keep typed words together. Only chords and pauses separate key groups.
function M.record(input, mode)
    local label = vim.fn.keytrans(input)
    M.log[#M.log + 1] = label
    local space = label == " " or label == "<Space>"
    local text = not label:match("^<.*>$") and not space
    if space then
        text = mode:match("^[ic]") ~= nil
        label = text and " " or "Space"
    end
    label = shortcuts[label] or (label == "<CR>" and "Enter") or label
    local now = (vim.uv or vim.loop).hrtime()
    if text and M.last_text and now - M.last_time < 600000000 and #M.history > 0 then
        M.history[#M.history] = M.history[#M.history] .. label
    else
        M.history[#M.history + 1] = label
    end
    M.last_text, M.last_time = text, now
    local limit = math.max(18, math.min(58, vim.o.columns - 8))
    while #M.history > 1 and vim.fn.strdisplaywidth(table.concat(M.history, " ")) > limit do
        table.remove(M.history, 1)
    end
    while vim.fn.strdisplaywidth(table.concat(M.history, " ")) > limit do
        M.history[1] = vim.fn.strcharpart(M.history[1], 1)
    end
end

function M.setup()
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.on_key(function(key, typed)
        local input = typed == nil and key or typed
        if input == "" then
            return
        end
        M.record(input, vim.api.nvim_get_mode().mode)
        vim.schedule(M.render)
    end, ns)
    vim.api.nvim_create_autocmd("VimResized", { callback = M.render })
end

return M
