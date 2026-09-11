local M = {}

function M.register()
    vim.api.nvim_create_user_command("Tasks", function()
        require("taskbuffer").tasks()
    end, {})

    vim.api.nvim_create_user_command("TasksClear", function()
        require("taskbuffer").tasks_clear()
    end, {})

    vim.api.nvim_create_user_command("TasksUndated", function()
        local buffer = require("taskbuffer.buffer")
        buffer.set_show_undated(true)
        require("taskbuffer").tasks()
    end, {})

    vim.api.nvim_create_user_command("TasksProfile", function(opts)
        local profile = require("taskbuffer.profile")
        local action = opts.args ~= "" and opts.args or "report"
        if action == "start" or action == "stop" or action == "reset" then
            profile[action]()
        elseif action ~= "report" then
            vim.notify("[taskbuffer] use :TasksProfile [start|stop|reset|report]", vim.log.levels.ERROR)
            return
        end
        if action == "report" or action == "stop" then
            vim.notify(profile.report(), vim.log.levels.INFO)
        else
            vim.notify("[taskbuffer] profile " .. action, vim.log.levels.INFO)
        end
    end, {
        nargs = "?",
        complete = function(lead)
            return vim.tbl_filter(function(action)
                return action:sub(1, #lead) == lead
            end, { "start", "stop", "reset", "report" })
        end,
        desc = "Record and report taskbuffer performance",
    })
end

return M
