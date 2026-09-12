-- Presentation for this isolated demo only. Taskbuffer calls vim.ui.select;
-- normal installations use their own provider or Neovim's built-in menu.
local M = {}

function M.select(items, opts, on_choice)
    local entries = {}
    for index, item in ipairs(items) do
        local label = (opts.format_item or tostring)(item)
        entries[index] = { value = item, index = index, display = label, ordinal = label }
    end
    local answered = false
    local function finish(item, index)
        if answered then
            return
        end
        answered = true
        on_choice(item, index)
    end
    local actions = require("telescope.actions")
    require("telescope.pickers")
        .new({}, {
            prompt_title = opts.prompt,
            finder = require("telescope.finders").new_table({
                results = entries,
                entry_maker = function(entry)
                    return entry
                end,
            }),
            sorter = require("telescope.config").values.generic_sorter({}),
            attach_mappings = function(buf)
                vim.api.nvim_create_autocmd("BufWipeout", {
                    buffer = buf,
                    once = true,
                    callback = function()
                        vim.schedule(function()
                            finish(nil, nil)
                        end)
                    end,
                })
                actions.select_default:replace(function()
                    local entry = require("telescope.actions.state").get_selected_entry()
                    actions.close(buf)
                    finish(entry and entry.value, entry and entry.index)
                end)
                return true
            end,
        })
        :find()
end

return M
