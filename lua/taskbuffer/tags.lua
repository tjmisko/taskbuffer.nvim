local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local M = {}

function M.pick_tags()
    local tb = require("taskbuffer")
    local config = tb.config
    local buffer = require("taskbuffer.buffer")

    local cmd = config.task_bin
    for _, arg in ipairs(tb.source_args()) do
        cmd = cmd .. " " .. vim.fn.shellescape(arg)
    end
    cmd = cmd .. " tags 2>/dev/null"

    local handle = io.popen(cmd)
    if not handle then
        vim.notify("Failed to run task tags", vim.log.levels.ERROR)
        return
    end
    local output = handle:read("*a")
    handle:close()

    local tags = {}
    for line in output:gmatch("[^\n]+") do
        table.insert(tags, line)
    end

    if #tags == 0 then
        vim.notify("No tags found", vim.log.levels.WARN)
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

                    local filepath = config.tmpdir .. "/" .. os.date("%Y-%m-%d") .. ".taskfile"
                    vim.cmd("edit! " .. filepath)
                    vim.bo.readonly = true
                    buffer.set_refreshing(false)
                    vim.notify("Filtering by: " .. table.concat(selected_tags, ", "), vim.log.levels.INFO)
                end)
                return true
            end,
        })
        :find()
end

return M
