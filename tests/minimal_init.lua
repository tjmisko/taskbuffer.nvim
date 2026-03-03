-- Minimal init for running plenary.nvim tests headlessly.
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

-- Isolate test environment
local tmp = vim.fn.tempname()
vim.env.XDG_CONFIG_HOME = tmp .. "/config"
vim.env.XDG_STATE_HOME = tmp .. "/state"
vim.env.XDG_DATA_HOME = tmp .. "/data"

-- Determine project root from this file's location
local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
local project_root = vim.fn.fnamemodify(script_dir, ":h")

-- Add project and plenary to rtp
vim.opt.rtp:prepend(project_root)

-- Try common plenary locations (including CI clone path)
local plenary_paths = {
    vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
    vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
    project_root .. "/.deps/plenary.nvim",
}

for _, p in ipairs(plenary_paths) do
    if vim.fn.isdirectory(p) == 1 then
        vim.opt.rtp:prepend(p)
        break
    end
end

-- Load plenary test harness
vim.cmd("runtime plugin/plenary.vim")
