local M = {}

function M.pick_tags()
    local ok, pickers = pcall(require, "telescope.pickers")
    if not ok then
        vim.notify("[taskbuffer] telescope.nvim is required for tag filtering", vim.log.levels.ERROR)
        return
    end
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local config = require("taskbuffer.config")
    local cfg = config.values
    local buffer = require("taskbuffer.buffer")

    local cmd = cfg.task_bin
    for _, arg in ipairs(config.source_args()) do
        cmd = cmd .. " " .. vim.fn.shellescape(arg)
    end
    cmd = cmd .. " tags 2>/dev/null"

    local handle = io.popen(cmd)
    if not handle then
        vim.notify("[taskbuffer] failed to run task tags", vim.log.levels.ERROR)
        return
    end
    local output = handle:read("*a")
    handle:close()

    local tags = {}
    for line in output:gmatch("[^\n]+") do
        table.insert(tags, line)
    end

    if #tags == 0 then
        vim.notify("[taskbuffer] no tags found", vim.log.levels.WARN)
        return
    end

    local current_filter = buffer.get_tag_filter()

    pickers
        .new({}, {
            prompt_title = "Filter Tasks by Tag"
                .. (#current_filter > 0 and " (active: " .. table.concat(current_filter, ", ") .. ")" or ""),
            finder = finders.new_table({ results = tags }),
            sorter = conf.generic_sorter({}),
            attach_mappings = function(prompt_bufnr, _)
                actions.select_default:replace(function()
                    local picker = action_state.get_current_picker(prompt_bufnr)
                    local selections = picker:get_multi_selection()
                    actions.close(prompt_bufnr)

                    local selected_tags = {}
                    if #selections > 0 then
                        for _, entry in ipairs(selections) do
                            table.insert(selected_tags, entry[1])
                        end
                    else
                        local entry = action_state.get_selected_entry()
                        if entry then
                            table.insert(selected_tags, entry[1])
                        end
                    end

                    buffer.set_tag_filter(selected_tags)
                    buffer.set_refreshing(true)
                    buffer.refresh_taskfile()

                    local filepath = cfg.tmpdir .. "/" .. os.date("%Y-%m-%d") .. ".taskfile"
                    vim.cmd("edit! " .. filepath)
                    vim.bo.readonly = true
                    buffer.set_refreshing(false)
                    vim.notify("[taskbuffer] filtering by: " .. table.concat(selected_tags, ", "), vim.log.levels.INFO)
                end)
                return true
            end,
        })
        :find()
end

return M
