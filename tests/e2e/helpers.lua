-- Shared test helpers for e2e smoke tests.
local M = {}

M.passed = 0
M.failed = 0

function M.check(name, ok, err)
    if ok then
        M.passed = M.passed + 1
        io.write("PASS: " .. name .. "\n")
    else
        M.failed = M.failed + 1
        io.write("FAIL: " .. name .. " — " .. tostring(err) .. "\n")
    end
end

function M.check_setup(opts)
    local ok, err = pcall(function()
        if type(opts) == "table" and opts.formats then
            -- Full config table with format overrides
            opts.sources = opts.sources or { "/root/Documents/Notes" }
            require("taskbuffer").setup(opts)
        else
            -- Legacy: opts is a sources list or nil
            require("taskbuffer").setup({
                sources = opts or { "/root/Documents/Notes" },
            })
        end
    end)
    M.check("setup() completes without error", ok, err)
end

function M.check_health()
    local ok, err = pcall(function()
        local result = vim.api.nvim_exec2("checkhealth taskbuffer", { output = true })
        local output = result.output or ""
        for line in output:gmatch("[^\n]+") do
            if line:find("ERROR") then
                error("checkhealth reported: " .. line)
            end
        end
    end)
    M.check(":checkhealth taskbuffer has no errors", ok, err)
end

function M.check_tasks()
    local ok, err = pcall(function()
        require("taskbuffer").tasks()

        vim.wait(5000, function()
            local buf = vim.api.nvim_get_current_buf()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            return #lines > 1
        end, 100)

        local buf = vim.api.nvim_get_current_buf()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        if #lines <= 1 then
            error("taskfile buffer has " .. #lines .. " lines, expected >1")
        end
    end)
    M.check(":Tasks produces output", ok, err)
end

function M.check_content(expected)
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local content = table.concat(lines, "\n")
    for _, needle in ipairs(expected) do
        local ok = content:find(needle, 1, true) ~= nil
        M.check("buffer contains: " .. needle, ok, "not found in buffer output")
    end
end

function M.check_absent(unexpected)
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local content = table.concat(lines, "\n")
    for _, needle in ipairs(unexpected) do
        local ok = content:find(needle, 1, true) == nil
        M.check("buffer does NOT contain: " .. needle, ok, "unexpectedly found in buffer")
    end
end

function M.finish()
    io.write("\n")
    io.write(string.format("Results: %d passed, %d failed\n", M.passed, M.failed))

    if M.failed > 0 then
        vim.cmd("cquit 1")
    else
        vim.cmd("quit")
    end
end

return M
