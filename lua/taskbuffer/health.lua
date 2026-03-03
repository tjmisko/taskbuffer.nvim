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

    -- 2. Go binary
    if vim.fn.executable(config.task_bin) == 1 then
        vim.health.ok("Go binary found: " .. config.task_bin)
    else
        vim.health.error("Go binary not found: " .. config.task_bin, {
            "Run: cd " .. vim.fn.fnamemodify(config.task_bin, ":h") .. " && go build -o task_bin .",
        })
    end

    -- 3. ripgrep
    if vim.fn.executable("rg") == 1 then
        vim.health.ok("ripgrep (rg) found")
    else
        vim.health.error("ripgrep (rg) not found", { "Install ripgrep: https://github.com/BurntSushi/ripgrep" })
    end

    -- 4. Source directories
    for _, src in ipairs(config.sources) do
        if vim.fn.isdirectory(src) == 1 then
            vim.health.ok("Source directory exists: " .. src)
        else
            vim.health.warn("Source directory not found: " .. src)
        end
    end

    -- 5. telescope.nvim (optional)
    local has_telescope = pcall(require, "telescope")
    if has_telescope then
        vim.health.ok("telescope.nvim available (tag picker enabled)")
    else
        vim.health.info("telescope.nvim not found (tag picker disabled)")
    end
end

return M
