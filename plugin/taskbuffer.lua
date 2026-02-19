vim.api.nvim_create_user_command("Tasks", function()
    require("taskbuffer").tasks()
end, {})

vim.api.nvim_create_user_command("TasksClear", function()
    require("taskbuffer").tasks_clear()
end, {})
