local M = {}

local keymaps_registered = false

local function parse_taskfile_line(line)
    local filepath = string.sub(line, 1, string.find(line, ":") - 1)
    local second_colon = string.find(line, ":", string.find(line, ":") + 1)
    local linenumber = tonumber(string.sub(line, string.find(line, ":") + 1, second_colon - 1))
    return filepath, linenumber
end

local function replace_line_in_file(path, target_line, new_content)
    local lines = {}
    local i = 0
    for line in io.lines(path) do
        i = i + 1
        if i == target_line then
            lines[#lines + 1] = new_content
        else
            lines[#lines + 1] = line
        end
    end
    local f = assert(io.open(path, "w"))
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
end

local function append_to_line(path, target_line, suffix)
    local lines = {}
    local i = 0
    for line in io.lines(path) do
        i = i + 1
        if i == target_line then
            line = line .. suffix
        end
        lines[#lines + 1] = line
    end
    local f = assert(io.open(path, "w"))
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
end

local function shift_date_in_string(line, days)
    local prefix, y, m, d, suffix = line:match("^(.-%(@%[%[)(%d%d%d%d)%-(%d%d)%-(%d%d)(%]%].*)$")
    if not y then
        return nil, nil
    end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
    local new_t = t + days * 86400
    local new_date = os.date("%Y-%m-%d", new_t)
    return prefix .. new_date .. suffix, new_date
end

local function get_visual_selection()
    local s_mark = vim.api.nvim_buf_get_mark(0, "<")
    local e_mark = vim.api.nvim_buf_get_mark(0, ">")
    local s_line, s_col = s_mark[1], s_mark[2]
    local e_line, e_col = e_mark[1], e_mark[2]

    if s_line == 0 or e_line == 0 then
        return {}
    end

    if s_line == e_line then
        local line_text = vim.api.nvim_buf_get_lines(0, s_line - 1, s_line, false)[1]
        return { line_text:sub(s_col, e_col) }
    end

    local lines = vim.api.nvim_buf_get_lines(0, s_line - 1, e_line, false)
    if #lines == 0 then
        return {}
    end

    lines[1] = lines[1]:sub(s_col)
    lines[#lines] = lines[#lines]:sub(1, e_col)
    return lines
end

local function set_quickfix_task_list()
    local lines = get_visual_selection()
    local qf_list = {}
    for _, line in ipairs(lines) do
        local filename, lnum, _, text = string.match(line, "^(.-):(.-):(.-):(.*)$")
        local qf_line = { filename = filename, lnum = lnum, text = text }
        table.insert(qf_list, qf_line)
    end
    vim.fn.setqflist(qf_list, "r")
    vim.cmd("copen")
end

local function task_complete()
    local line_text = vim.api.nvim_get_current_line()
    if not string.find(line_text, "- %[ %]", 1) then
        print("No Task to Complete!")
        return
    end
    line_text = string.gsub(line_text, "- %[ %]", "- %[x%]", 1)
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local line_number = cursor_pos[1]
    local completed_marker = "::complete [[" .. os.date("%Y-%m-%d") .. "]] " .. os.date("%H:%M")
    vim.api.nvim_buf_set_lines(0, line_number - 1, line_number, true, { line_text .. completed_marker })
end

local function shift_task_date_in_taskfile(days)
    local buffer = require("taskbuffer.buffer")
    local line = vim.api.nvim_get_current_line()
    local filepath, linenumber = parse_taskfile_line(line)
    if not filepath or not linenumber then
        vim.notify("Could not parse taskfile line", vim.log.levels.WARN)
        return
    end
    local i = 0
    local source_line
    for l in io.lines(filepath) do
        i = i + 1
        if i == linenumber then
            source_line = l
            break
        end
    end
    if not source_line then
        vim.notify("Could not read source line", vim.log.levels.WARN)
        return
    end
    local new_line, new_date = shift_date_in_string(source_line, days)
    if not new_line then
        vim.notify("No date found on this line", vim.log.levels.WARN)
        return
    end
    replace_line_in_file(filepath, linenumber, new_line)
    local cursor = vim.api.nvim_win_get_cursor(0)
    buffer.set_refreshing(true)
    buffer.refresh_taskfile()
    vim.cmd("edit!")
    vim.bo.readonly = true
    buffer.set_refreshing(false)
    pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    vim.notify("Due: " .. new_date, vim.log.levels.INFO)
end

local function shift_task_date_in_markdown(days)
    local line = vim.api.nvim_get_current_line()
    local new_line, new_date = shift_date_in_string(line, days)
    if not new_line then
        vim.notify("No date found on this line", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_set_current_line(new_line)
    vim.notify("Due: " .. new_date, vim.log.levels.INFO)
end

function M.setup_keymaps()
    if keymaps_registered then
        return
    end
    keymaps_registered = true

    local augroup = vim.api.nvim_create_augroup("TaskBufferKeymaps", { clear = true })

    -- Global keymaps (not buffer-local)
    vim.keymap.set("n", "<leader>ev", 'o<Tab>- [[<Esc>ma:pu=strftime(\'%F\')<CR>"aDdd`a"apa]]: ')
    vim.keymap.set("n", "<leader>tc", task_complete)
    vim.keymap.set("n", "<leader>td", function()
        local line = vim.fn.getline(".")
        if not string.find(line, "::original") then
            vim.cmd('normal mf_"ayi(_$a::original ', false)
            vim.cmd('normal "apF@x`f')
        end
        vim.cmd("normal $a ::deferral [[")
        vim.cmd("pu=strftime('%F')")
        vim.cmd("normal $a]]")
        vim.cmd("pu=strftime('%R')")
        vim.cmd("normal 2kJxJ_f@6e")
    end)
    vim.keymap.set("n", "<leader>tx", function()
        local line_text = vim.api.nvim_get_current_line()
        if not string.find(line_text, "- %[ %]", 1) then
            print("No Task to Complete!")
            return
        end
        line_text = string.gsub(line_text, "- %[ %]", "- %[x%]", 1)
        local cursor_pos = vim.api.nvim_win_get_cursor(0)
        local line_number = cursor_pos[1]
        vim.api.nvim_buf_set_lines(0, line_number - 1, line_number, true, { line_text })
    end)

    vim.keymap.set(
        "n",
        "<leader>ti",
        'mf_f[lr-A::irrelevant [[<Esc>ma:pu=strftime(\'%F\')<CR>"aDdd`a"apa]] <Esc>ma:pu=strftime(\'%R\')<CR>"aDdd`a"ap`f'
    )
    vim.keymap.set("n", "<leader>tu", "mf_f[lr `fh")
    vim.keymap.set({ "n", "v" }, "<M-C-q>", set_quickfix_task_list)

    -- Taskfile-specific keymaps
    vim.api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = { "taskfile" },
        callback = function()
            local config = require("taskbuffer").config
            local state_path = config.state_dir .. "/current_task"

            vim.keymap.set("n", "<leader>tb", function()
                local f = io.open(state_path, "r")
                if f then
                    f:close()
                    os.execute(config.task_bin .. " stop")
                end
                local line = vim.fn.getline(".")
                local filepath = string.sub(line, 1, string.find(line, ":") - 1)
                local linenumber = string.sub(
                    line,
                    string.find(line, ":") + 1,
                    string.find(line, ":", string.find(line, ":") + 1) - 1
                )
                local datetime = os.time()
                local function trim(s)
                    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
                end
                local task_content = string.match(line, "^.-|.-|.-|(.*)$")
                task_content = task_content and task_content:match("^(.-)%s*::") or task_content
                if task_content then
                    task_content = trim(task_content)
                end
                local g = assert(io.open(state_path, "w"))
                g:write(datetime .. "\t" .. task_content .. "\t" .. filepath .. "\t" .. linenumber)
                g:close()
                local start_suffix = " ::start " .. os.date("[[%F]] %R")
                append_to_line(filepath, tonumber(linenumber), start_suffix)
            end, { buffer = true, desc = "Start task" })

            vim.keymap.set("n", "gf", function()
                vim.cmd('normal _3f|w')
                vim.cmd('normal! "gy3E')
                local line = vim.fn.getline(".")
                local filepath = string.sub(line, 1, string.find(line, ":") - 1)
                local linenumber = string.sub(
                    line,
                    string.find(line, ":") + 1,
                    string.find(line, ":", string.find(line, ":") + 1) - 1
                )
                vim.cmd("e " .. filepath)
                vim.cmd("normal " .. linenumber .. "G")
                vim.cmd("normal zz")
            end, { buffer = true, desc = "Go to task source" })

            vim.keymap.set(
                "n",
                "<leader>ti",
                'mf_f[lr-A::irrelevant [[<Esc>ma:pu=strftime(\'%F\')<CR>"aDdd`a"apa]] <Esc>ma:pu=strftime(\'%R\')<CR>"aDdd`a"ap`f',
                { buffer = true }
            )
            vim.keymap.set("n", "<leader>tu", "mf_f[lr `fh", { buffer = true })
            vim.keymap.set(
                "n",
                "<leader>tp",
                'mf_f[lr~A::partial [[<Esc>ma:pu=strftime(\'%F\')<CR>"aDdd`a"apa]] <Esc>ma:pu=strftime(\'%R\')<CR>"aDdd`a"ap`f',
                { buffer = true }
            )

            vim.keymap.set("n", "<M-Left>", function()
                shift_task_date_in_taskfile(-vim.v.count1)
            end, { buffer = true, desc = "Shift task date back" })
            vim.keymap.set("n", "<M-Right>", function()
                shift_task_date_in_taskfile(vim.v.count1)
            end, { buffer = true, desc = "Shift task date forward" })
        end,
    })

    -- Markdown date shift keymaps
    vim.api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = { "markdown" },
        callback = function()
            vim.keymap.set("n", "<M-Left>", function()
                shift_task_date_in_markdown(-vim.v.count1)
            end, { buffer = true, desc = "Shift task date back" })
            vim.keymap.set("n", "<M-Right>", function()
                shift_task_date_in_markdown(vim.v.count1)
            end, { buffer = true, desc = "Shift task date forward" })
        end,
    })
end

return M
