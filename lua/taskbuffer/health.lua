local M = {}

function M.check()
    vim.health.start("taskbuffer.nvim")

    -- 1. Neovim version
    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10")
    else
        vim.health.error("Neovim >= 0.10 required", { "Upgrade Neovim to 0.10 or later" })
    end

    local config = require("taskbuffer.config").values

    -- 2. Source directories
    for _, src in ipairs(config.sources) do
        if vim.fn.isdirectory(src) == 1 then
            vim.health.ok("Source directory exists: " .. src)
        else
            vim.health.warn("Source directory not found: " .. src)
        end
    end

    vim.health.ok("Tag picker uses vim.ui.select (built-in or configured provider)")
end

return M
