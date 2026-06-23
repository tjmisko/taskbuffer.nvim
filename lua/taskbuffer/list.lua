-- list.lua — the in-process pipeline that produces the taskfile list and tags.
--
-- Mirrors main.go:cmdList (163-231) and cmdTags (383-418) step for step. This
-- is the only new seam with no Go counterpart: it assembles scan -> parse ->
-- frontmatter -> horizon -> format into the byte-exact taskfile text that
-- buffer.lua already knows how to render.

local context = require("taskbuffer.context")
local scan = require("taskbuffer.scan")
local parse = require("taskbuffer.parse")
local frontmatter = require("taskbuffer.frontmatter")
local horizon = require("taskbuffer.horizon")
local format = require("taskbuffer.format")
local strftime = require("taskbuffer.strftime")

local M = {}

-- scan -> parse -> frontmatter merge/filter/inherit -> + project tasks.
-- Mirrors cmdList:186-195. Collects date errors into `date_errors` (which the
-- caller passes to parse via ctx.date_errors and to frontmatter explicitly).
local function build_tasks(ctx, matches, date_errors)
    frontmatter.reset()
    ctx.date_errors = date_errors -- parse_tasks collects inline/marker errors here

    local tasks = parse.parse_tasks(matches, ctx)
    frontmatter.merge_tags(tasks)
    tasks = frontmatter.filter_completed(tasks, ctx.fm_cfg) -- BEFORE inherit (order load-bearing)
    frontmatter.merge_due(tasks, ctx.fm_cfg, ctx.date_fmt, date_errors)

    local project_files = scan.scan_project_paths(ctx) or {}
    for _, p in ipairs(project_files) do
        local t = frontmatter.project_task(p, ctx.fm_cfg, ctx.date_fmt, date_errors)
        if t then
            tasks[#tasks + 1] = t
        end
    end
    return tasks
end

local function open_only(tasks)
    local out = {}
    for _, t in ipairs(tasks) do
        if t.status == "open" then
            out[#out + 1] = t
        end
    end
    return out
end

local function format_opts(ctx)
    return {
        markers = ctx.markers,
        ignore_undated = ctx.ignore_undated,
        tag_filter = ctx.tags,
        tag_prefix = ctx.tag_prefix,
        marker_prefix = ctx.marker_prefix,
        horizons = horizon.resolve(ctx.horizons, ctx.now, ctx.week_start, ctx.horizons_overlap),
        overlap = ctx.horizons_overlap,
        date_strftime = ctx.date_fmt,
    }
end

-- Render the taskfile text from a built ctx + raw matches. Returns text, or
-- nil + error string when strict mode collected invalid dates (cmdList:204
-- aborts and writes nothing).
local function render(ctx, matches)
    local date_errors = ctx.strict and {} or nil
    local tasks = build_tasks(ctx, matches, date_errors)
    local open = open_only(tasks)

    if ctx.strict and date_errors and #date_errors > 0 then
        local msgs = {}
        for _, e in ipairs(date_errors) do
            msgs[#msgs + 1] = strftime.format_date_error(e)
        end
        return nil, table.concat(msgs, "\n")
    end

    return format.format_taskfile(open, ctx.now, format_opts(ctx))
end

--- Synchronous list. Returns the byte-exact taskfile text (or nil, err).
---@param opts table|nil  -- { markers, ignore_undated, tags, now }
---@return string|nil text, string|nil err
function M.list(opts)
    local config = require("taskbuffer.config").values
    local ctx = context.build_context(config, opts or {})
    local matches, err = scan.scan(ctx)
    if err then
        return nil, err
    end
    return render(ctx, matches or {})
end

--- Async list: rg runs off the UI loop, then parse/format run on the main
--- thread in the scheduled callback (overview D1). cb(text, err).
---@param opts table|nil
---@param cb fun(text:string|nil, err:string|nil)
function M.list_async(opts, cb)
    local config = require("taskbuffer.config").values
    local ctx = context.build_context(config, opts or {})
    scan.scan_async(ctx, function(matches, err)
        if err then
            cb(nil, err)
            return
        end
        local text, rerr = render(ctx, matches or {})
        cb(text, rerr)
    end)
end

--- Unique, sorted open-task tags. Mirrors cmdTags (383-418): scan -> parse ->
--- merge_tags -> + project tasks -> collect tags of status=="open" tasks.
--- NOTE (Go parity): cmdTags does NOT filter_completed or merge_due.
---@param opts table|nil
---@return string[] tags, string|nil err
function M.tags(opts)
    local config = require("taskbuffer.config").values
    local ctx = context.build_context(config, opts or {})
    local matches, err = scan.scan(ctx)
    if err then
        return {}, err
    end

    frontmatter.reset()
    ctx.date_errors = nil
    local tasks = parse.parse_tasks(matches or {}, ctx)
    frontmatter.merge_tags(tasks)

    local project_files = scan.scan_project_paths(ctx) or {}
    for _, p in ipairs(project_files) do
        local t = frontmatter.project_task(p, ctx.fm_cfg, ctx.date_fmt, nil)
        if t then
            tasks[#tasks + 1] = t
        end
    end

    local seen = {}
    for _, t in ipairs(tasks) do
        if t.status == "open" then
            for _, tag in ipairs(t.tags or {}) do
                seen[tag] = true
            end
        end
    end
    local out = {}
    for tag in pairs(seen) do
        out[#out + 1] = tag
    end
    table.sort(out)
    return out, nil
end

return M
