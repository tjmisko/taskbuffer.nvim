local config = vim.json.decode(table.concat(vim.fn.readfile(vim.env.TASKBUFFER_DEMO_CONFIG), "\n"))
vim.opt.runtimepath =
    { vim.env.VIMRUNTIME, config.repo, config.deps .. "/plenary.nvim", config.deps .. "/telescope.nvim" }
package.path = config.repo .. "/scripts/demo/?.lua;" .. package.path
vim.opt.packpath = {}
vim.g.mapleader = " "
vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.shadafile = "NONE"
vim.opt.modeline = false
vim.opt.exrc = false
vim.opt.termguicolors = true
vim.opt.mouse = ""
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.signcolumn = "no"
vim.opt.wrap = false
vim.opt.scrolloff = 5
vim.opt.sidescrolloff = 3
vim.opt.laststatus = 2
vim.opt.showmode = false
vim.opt.ruler = false
vim.opt.timeoutlen = 1200
vim.opt.updatetime = 100
vim.opt.title = true
vim.opt.titlestring = "taskbuffer demo"
vim.opt.statusline = "  taskbuffer.nvim  %<%{&filetype ==# 'taskfile' ? 'Tasks' : expand('%:t')} %m%=%l:%c  "
-- Use syntax highlighting without depending on locally installed TS parsers.
vim.cmd("filetype plugin indent off")
vim.cmd("filetype on")
vim.cmd("syntax enable")
if vim.fn.isdirectory(config.deps .. "/catppuccin") == 1 then
    vim.opt.runtimepath:append(config.deps .. "/catppuccin")
    require("catppuccin").setup({ flavour = "mocha", transparent_background = false, default_integrations = false })
    vim.cmd.colorscheme("catppuccin")
else
    vim.cmd.colorscheme("habamax")
end
for group, attrs in pairs({
    TaskbufferDemo = { fg = "#cdd6f4", bg = "#313244" },
    TaskbufferDemoTitle = { fg = "#a6e3a1", bg = "#313244", bold = true },
    taskfileHeading = { fg = "#89b4fa", bold = true },
    taskfileOverdue = { fg = "#f38ba8", bold = true },
    taskfileDate = { fg = "#f9e2af" },
    taskfileTag = { fg = "#fab387" },
}) do
    vim.api.nvim_set_hl(0, group, attrs)
end
vim.api.nvim_create_autocmd("FileType", {
    pattern = "taskfile",
    callback = function()
        vim.opt_local.conceallevel = 2
        vim.opt_local.concealcursor = "nc"
        vim.opt_local.number = false
    end,
})
require("telescope").setup({
    defaults = {
        layout_strategy = "horizontal",
        layout_config = { width = 0.8, height = 0.55, prompt_position = "top" },
        sorting_strategy = "ascending",
        previewer = false,
    },
})
require("taskbuffer").setup({
    sources = { config.root .. "/vault" },
    tmpdir = config.root .. "/tmp",
    state_dir = config.root .. "/state",
    inbox = { file = config.root .. "/vault/inbox.md" },
})
vim.cmd("runtime plugin/taskbuffer.lua")
vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
        require("player").setup(config)
    end,
})
