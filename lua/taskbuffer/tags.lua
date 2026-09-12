local M = {}
local cancel_pending
local generation = 0
local pending_buf
local picking = false

function M.cancel(buf, hidden)
    -- Some vim.ui.select providers temporarily replace the source window.
    -- Hiding during selection is not cancellation; wiping the source still is.
    if hidden and picking then
        return
    end
    if pending_buf == buf then
        generation = generation + 1
        if cancel_pending then
            cancel_pending()
        end
        cancel_pending, pending_buf, picking = nil, nil, false
    end
end

function M.pick_tags()
    local buffer = require("taskbuffer.buffer")
    local config = require("taskbuffer.config").values

    if cancel_pending then
        cancel_pending()
    end
    generation = generation + 1
    local request = generation
    local source_buf = vim.api.nvim_get_current_buf()
    pending_buf = source_buf
    picking = false
    local function show(tags, err)
        if
            request ~= generation
            or vim.api.nvim_get_current_buf() ~= source_buf
            or config ~= require("taskbuffer.config").values
        then
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

        local current_filter = vim.list_slice(buffer.get_tag_filter())
        picking = true
        local answered = false
        vim.ui.select(tags, {
            prompt = "Filter Tasks by Tag"
                .. (#current_filter > 0 and " (toggle; active: " .. table.concat(current_filter, ", ") .. ")" or ""),
            kind = "taskbuffer_tags",
            format_item = function(tag)
                return (vim.tbl_contains(current_filter, tag) and "[x] " or "[ ] ") .. tag
            end,
        }, function(tag)
            if answered then
                return
            end
            answered = true
            -- Providers may call back before closing their window. Apply to the
            -- original view after the provider finishes, without stealing focus.
            vim.schedule(function()
                if request ~= generation then
                    return
                end
                pending_buf, cancel_pending, picking = nil, nil, false
                if
                    not tag
                    or not vim.api.nvim_buf_is_loaded(source_buf)
                    or config ~= require("taskbuffer.config").values
                then
                    return
                end
                local selected_tags = vim.list_slice(buffer.get_tag_filter())
                local removed = false
                for index, selected in ipairs(selected_tags) do
                    if selected == tag then
                        table.remove(selected_tags, index)
                        removed = true
                        break
                    end
                end
                if not removed then
                    selected_tags[#selected_tags + 1] = tag
                end
                buffer.set_tag_filter(selected_tags)
                buffer.refresh_taskfile_async(nil, { buf = source_buf, reuse = true })
                vim.notify(
                    #selected_tags > 0 and "[taskbuffer] filtering by: " .. table.concat(selected_tags, ", ")
                        or "[taskbuffer] tag filter cleared",
                    vim.log.levels.INFO
                )
            end)
        end)
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
