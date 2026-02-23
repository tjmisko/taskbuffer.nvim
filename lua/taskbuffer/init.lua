local M = {}

-- Auto-detect plugin root from this file's location
local script_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(script_path, ":h:h:h")

M.config = {
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
        checkbox = { open = "- [ ]", done = "- [x]", irrelevant = "- [-]" },
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

--- Deep merge that preserves `false` values (vim.tbl_deep_extend treats false as truthy
--- and would keep it, but we want explicit control).
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
local function expand_path(p)
    if type(p) ~= "string" then
        return p
    end
    return vim.fn.expand(p)
end

--- Expand paths in the config that represent filesystem locations.
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

function M.setup(opts)
    opts = opts or {}

    -- Backward compat: convert notes_dir to sources
    if opts.notes_dir then
        vim.notify(
            "[taskbuffer] `notes_dir` is deprecated, use `sources = { ... }` instead",
            vim.log.levels.WARN
        )
        if not opts.sources then
            opts.sources = { opts.notes_dir }
        end
        opts.notes_dir = nil
    end

    M.config = deep_merge(M.config, opts)
    expand_config_paths(M.config)

    require("taskbuffer.buffer").setup_autocmds()
    require("taskbuffer.keymaps").setup_keymaps()
end

--- Build the CLI args for source directories.
function M.source_args()
    local args = {}
    for _, src in ipairs(M.config.sources) do
        table.insert(args, "--source")
        table.insert(args, src)
    end
    return args
end

--- Build the --config JSON arg for format/state config.
function M.config_json_arg()
    local cfg = {
        state_dir = M.config.state_dir,
        date_format = M.config.formats.date,
        time_format = M.config.formats.time,
        date_wrapper = M.config.formats.date_wrapper,
        marker_prefix = M.config.formats.marker_prefix,
        tag_prefix = M.config.formats.tag_prefix,
        checkbox = M.config.formats.checkbox,
    }
    return vim.json.encode(cfg)
end

function M.tasks()
    require("taskbuffer.buffer").setup_autocmds()
    require("taskbuffer.keymaps").setup_keymaps()
    require("taskbuffer.buffer").tasks()
end

function M.tasks_clear()
    require("taskbuffer.buffer").setup_autocmds()
    require("taskbuffer.keymaps").setup_keymaps()
    require("taskbuffer.buffer").tasks_clear()
end

return M
