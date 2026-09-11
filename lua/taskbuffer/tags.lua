local M = {}
local cancel_pending
local generation = 0
local pending_buf

function M.cancel(buf)
    if pending_buf == buf then
        generation = generation + 1
        if cancel_pending then
            cancel_pending()
        end
        cancel_pending, pending_buf = nil, nil
    end
end

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

    local buffer = require("taskbuffer.buffer")

    if cancel_pending then
        cancel_pending()
    end
    generation = generation + 1
    local request = generation
    local source_buf = vim.api.nvim_get_current_buf()
    pending_buf = source_buf
    local function show(tags, err)
        if request ~= generation or vim.api.nvim_get_current_buf() ~= source_buf then
            return
        end
        if err then
            vim.notify("[taskbuffer] failed to collect tags: " .. err, vim.log.levels.ERROR)
            return
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
                        buffer.refresh_taskfile_async(nil, { buf = source_buf, reuse = true })
                        vim.notify(
                            "[taskbuffer] filtering by: " .. table.concat(selected_tags, ", "),
                            vim.log.levels.INFO
                        )
                    end)
                    return true
                end,
            })
            :find()
    end
    local function fetch(err)
        if request ~= generation or vim.api.nvim_get_current_buf() ~= source_buf then
            return
        end
        if err then
            show(nil, err)
            return
        end
        cancel_pending = require("taskbuffer.list").tags_async({}, show)
    end
    if buffer.get_refreshing() then
        -- Join the in-flight snapshot instead of starting two more scans.
        buffer.refresh_taskfile_async(fetch, { buf = source_buf, reuse = true })
    else
        fetch()
    end
end

return M
