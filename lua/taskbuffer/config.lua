---@class TaskbufferCheckbox
---@field open string
---@field done string
---@field irrelevant string

---@class TaskbufferFormats
---@field date string strftime format for dates
---@field time string strftime format for times
---@field duration string duration template
---@field tag_prefix string prefix character for tags
---@field checkbox TaskbufferCheckbox checkbox markers
---@field date_wrapper string[] two-element array for date wrapping
---@field marker_prefix string prefix for state markers

---@class TaskbufferGlobalKeymaps
---@field complete string|false
---@field defer string|false
---@field check_off string|false
---@field irrelevant string|false
---@field undo_irrelevant string|false
---@field quickfix string|false
---@field note string|false

---@class TaskbufferTaskfileKeymaps
---@field start_task string|false
---@field go_to_file string|false
---@field partial string|false
---@field irrelevant string|false
---@field undo_irrelevant string|false
---@field filter_tags string|false
---@field reset_filters string|false
---@field toggle_markers string|false
---@field toggle_undated string|false
---@field shift_date_back string|false
---@field shift_date_forward string|false

---@class TaskbufferMarkdownKeymaps
---@field shift_date_back string|false
---@field shift_date_forward string|false

---@class TaskbufferKeymaps
---@field global TaskbufferGlobalKeymaps
---@field taskfile TaskbufferTaskfileKeymaps
---@field markdown TaskbufferMarkdownKeymaps

---@class TaskbufferInbox
---@field file string path to inbox markdown file
---@field header string|nil optional heading to insert below

---@class TaskbufferConfig
---@field task_bin string path to the Go binary
---@field state_dir string directory for task state files
---@field tmpdir string directory for temporary taskfile output
---@field show_undated boolean whether to show undated tasks by default
---@field sources string[] directories or glob patterns to scan
---@field inbox TaskbufferInbox default location for new tasks
---@field formats TaskbufferFormats task syntax formats
---@field keymaps TaskbufferKeymaps keymap bindings

---@class TaskbufferConfigModule
---@field defaults TaskbufferConfig
---@field values TaskbufferConfig
local M = {}

-- Auto-detect plugin root from this file's location
local script_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(script_path, ":h:h:h")

---@type TaskbufferConfig
M.defaults = {
    task_bin = plugin_root .. "/go/task_bin",
    state_dir = "~/.local/state/task",
    tmpdir = "/tmp",

    show_undated = true,

    -- Task sources: directories (recursive) or glob patterns
    sources = { "~/Documents/Notes" },

    -- Default location for new tasks created via `task create`
    inbox = {
        file = "~/Documents/Notes/inbox.md",
        header = nil,
    },

    -- Task syntax formats (passed to Go binary)
    formats = {
        date = "%Y-%m-%d",
        time = "%H:%M",
        duration = "<{n}m>",
        tag_prefix = "#",
        checkbox = { open = "- [ ]", done = "- [x]", irrelevant = "- [-]", partial = "- [~]" },
        date_wrapper = { "(@[[", "]])" },
        marker_prefix = "::",
    },

    -- Keymaps: set to false to disable, or override the key string
    keymaps = {
        global = {
            complete = "<leader>tc",
            defer = "<leader>td",
            check_off = "<leader>tx",
            irrelevant = "<leader>ti",
            undo_irrelevant = "<leader>tu",
            quickfix = "<M-C-q>",
            note = "<leader>ev",
        },
        taskfile = {
            start_task = "<leader>tb",
            go_to_file = "gf",
            partial = "<leader>tp",
            irrelevant = "<leader>ti",
            undo_irrelevant = "<leader>tu",
            filter_tags = "#",
            reset_filters = "<leader>tt",
            toggle_markers = "<leader>tj",
            toggle_undated = "<leader>ts",
            shift_date_back = "<M-Left>",
            shift_date_forward = "<M-Right>",
        },
        markdown = {
            shift_date_back = "<M-Left>",
            shift_date_forward = "<M-Right>",
        },
    },
}

--- Current resolved config values; populated by apply().
---@type TaskbufferConfig
M.values = vim.deepcopy(M.defaults)

--- Deep merge that preserves `false` values (vim.tbl_deep_extend treats false as truthy
--- and would keep it, but we want explicit control).
---@param base table
---@param override table
---@return table
local function deep_merge(base, override)
    local result = {}
    for k, v in pairs(base) do
        result[k] = v
    end
    for k, v in pairs(override) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = deep_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

--- Expand ~ in a string path.
---@param p any
---@return any
local function expand_path(p)
    if type(p) ~= "string" then
        return p
    end
    return vim.fn.expand(p)
end

--- Expand paths in the config that represent filesystem locations.
---@param cfg TaskbufferConfig
local function expand_config_paths(cfg)
    cfg.task_bin = expand_path(cfg.task_bin)
    cfg.state_dir = expand_path(cfg.state_dir)
    cfg.tmpdir = expand_path(cfg.tmpdir)

    for i, src in ipairs(cfg.sources) do
        cfg.sources[i] = expand_path(src)
    end

    if cfg.inbox then
        cfg.inbox.file = expand_path(cfg.inbox.file)
    end
end

--- Merge user options into defaults and expand paths.
---@param opts TaskbufferConfig|nil
function M.apply(opts)
    opts = opts or {}

    -- Backward compat: convert notes_dir to sources
    if opts.notes_dir then
        vim.notify("[taskbuffer] `notes_dir` is deprecated, use `sources = { ... }` instead", vim.log.levels.WARN)
        if not opts.sources then
            opts.sources = { opts.notes_dir }
        end
        opts.notes_dir = nil
    end

    M.values = deep_merge(M.defaults, opts)
    expand_config_paths(M.values)
end

--- Build the CLI args for source directories.
---@return string[]
function M.source_args()
    local args = {}
    for _, src in ipairs(M.values.sources) do
        table.insert(args, "--source")
        table.insert(args, src)
    end
    return args
end

--- Build the --config JSON arg for format/state config.
---@return string
function M.config_json_arg()
    local cfg = {
        state_dir = M.values.state_dir,
        date_format = M.values.formats.date,
        time_format = M.values.formats.time,
        date_wrapper = M.values.formats.date_wrapper,
        marker_prefix = M.values.formats.marker_prefix,
        tag_prefix = M.values.formats.tag_prefix,
        checkbox = M.values.formats.checkbox,
    }
    return vim.json.encode(cfg)
end

return M
