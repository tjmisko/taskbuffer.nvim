-- context.lua — builds the unified pipeline context (replaces Go's
-- NewParseContext + Config struct + the --config JSON boundary).
--
-- There is no JSON boundary after the rewrite: this reads config.values
-- directly and produces ONE plain Lua table threaded through every stage
-- (scan/parse/frontmatter/horizon/format/state/mutate). It starts from the
-- parse-context (which owns the regex/pattern construction) and augments it
-- with the fields the other stages read.

local parse = require("taskbuffer.parse")
local scan = require("taskbuffer.scan")
local frontmatter = require("taskbuffer.frontmatter")
local strftime = require("taskbuffer.strftime")

local M = {}

local DEFAULT_DATE_FMT = "%Y-%m-%d"
local DEFAULT_TIME_FMT = "%H:%M"

local function nonempty(s, default)
    if type(s) == "string" and s ~= "" then
        return s
    end
    return default
end

--- Build the unified context.
---@param config table       -- require("taskbuffer.config").values
---@param runtime table|nil  -- { markers=bool, ignore_undated=bool, tags=string[], now=epoch|nil }
---@return table ctx
function M.build_context(config, runtime)
    config = config or {}
    runtime = runtime or {}
    local formats = config.formats or {}

    -- Parse-context: checkbox/status_map/checkboxes, tag_prefix/tag_pat,
    -- date_spec/time_spec, date_pat_*, marker_prefix/marker_pat_*, strict,
    -- duration_pat, date_errors slot.
    local ctx = parse.new_parse_context(config)

    -- Sources (config.apply already ~-expanded them); copy defensively.
    ctx.sources = vim.deepcopy(config.sources or {})

    -- rg scan pattern from the (filtered) checkbox literals.
    ctx.scan_pattern = scan.build_pattern(ctx.checkbox)

    -- Raw strftime strings (state/mutate markers + format display).
    ctx.date_fmt = nonempty(formats.date, DEFAULT_DATE_FMT)
    ctx.time_fmt = nonempty(formats.time, DEFAULT_TIME_FMT)

    -- State directory for current_task.
    ctx.state_dir = config.state_dir

    -- Resolved frontmatter config (due_key/inherit_due/require_tags/status_key/done_values).
    ctx.fm_cfg = frontmatter.resolve_cfg(config.frontmatter)

    -- Horizon configuration.
    ctx.horizons = config.horizons -- specs or nil (-> default_horizon_specs)
    ctx.horizons_overlap = config.horizons_overlap or "sorted"
    ctx.week_start = config.week_start or "monday"

    -- Injected clock for deterministic bucketing/markers; normalized to local
    -- noon (overview §3.1). Defaults to the real clock.
    local base = runtime.now or os.time()
    ctx.now = strftime.start_of_day_noon(base)

    -- Per-invocation runtime flags (today's CLI args -markers/--ignore-undated/--tag).
    ctx.markers = runtime.markers == true
    ctx.ignore_undated = runtime.ignore_undated == true
    ctx.tags = runtime.tags or {}

    return ctx
end

return M
