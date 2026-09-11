-- Only configuration and lazy entry points belong on the startup path.
local M = {}
local configured
local global_keys = {}

function M.register()
    local cfg = require("taskbuffer.config").values
    if configured == cfg then
        return
    end
    configured = cfg
    for _, key in ipairs(global_keys) do
        pcall(vim.keymap.del, "n", key)
    end
    global_keys = {}
    local function map(action, rhs)
        local key = cfg.keymaps.global[action]
        if key then
            vim.keymap.set("n", key, rhs)
            global_keys[#global_keys + 1] = key
        end
    end
    map("note", "o<Tab>- [[<Esc>ma:pu=strftime('%F')<CR>\"aDdd`a\"apa]]: ")
    for action, verb in pairs({
        complete = "complete-at",
        defer = "defer",
        check_off = "check",
        irrelevant = "irrelevant",
        undo_irrelevant = "unset",
    }) do
        map(action, function()
            require("taskbuffer.keymaps").global_action(verb)
        end)
    end
    local group = vim.api.nvim_create_augroup("TaskBufferKeymaps", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = { "taskfile", "markdown" },
        callback = function(event)
            if event.match == "taskfile" then
                require("taskbuffer.keymaps").attach_taskfile()
            else
                for action, description in pairs({
                    set_date_today = "Set task date to today",
                    shift_date_back = "Shift task date back",
                    shift_date_forward = "Shift task date forward",
                }) do
                    local key = require("taskbuffer.config").values.keymaps.markdown[action]
                    if key then
                        vim.keymap.set("n", key, function()
                            require("taskbuffer.keymaps").markdown_action(action)
                        end, { buffer = event.buf, desc = description })
                    end
                end
            end
        end,
    })
    require("taskbuffer.autocmds").register()
end

return M
