-- Minimal reproduction config for bug reports.
-- Usage: nvim -u repro.lua

vim.env.LAZY_STDPATH = ".repro"
load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"))()

require("lazy.minit").repro({
    spec = {
        {
            "tjmisko/taskbuffer.nvim",
            build = "cd go && go build -o task_bin .",
            config = function()
                require("taskbuffer").setup({
                    sources = { "~/Documents/Notes" },
                })
            end,
        },
        -- Uncomment to test with telescope:
        -- {
        --     "nvim-telescope/telescope.nvim",
        --     dependencies = { "nvim-lua/plenary.nvim" },
        -- },
    },
})
