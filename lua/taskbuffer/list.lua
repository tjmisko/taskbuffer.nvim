-- Scan and build source data only on demand. Display options reuse the latest
-- snapshot; entering taskbuffer or mutating a source requests a fresh scan.
local context = require("taskbuffer.context")
local scan = require("taskbuffer.scan")
local parse = require("taskbuffer.parse")
local frontmatter = require("taskbuffer.frontmatter")
local horizon = require("taskbuffer.horizon")
local format = require("taskbuffer.format")
local strftime = require("taskbuffer.strftime")
local profile = require("taskbuffer.profile")
local async = require("taskbuffer.async")

local M = {}
local cached
local revision = 0

function M.invalidate()
    revision = revision + 1
    cached = nil
end

local function add_tags(seen, tasks)
    for _, task in ipairs(tasks) do
        async.checkpoint()
        if task.status == "open" then
            for _, tag in ipairs(task.tags or {}) do
                seen[tag] = true
            end
        end
    end
end

local function sorted_tags(seen)
    local tags = {}
    for tag in pairs(seen) do
        tags[#tags + 1] = tag
    end
    async.sort(tags, function(a, b)
        return a < b
    end)
    return tags
end

local function build_tasks(ctx, matches, projects, tags_only)
    frontmatter.reset()
    local errors = ctx.strict and not tags_only and {} or nil
    ctx.date_errors = errors
    local tasks = profile.measure("parse", parse.parse_tasks, matches, ctx)
    profile.measure("frontmatter.tags", frontmatter.merge_tags, tasks)
    -- Tag queries deliberately include tasks before frontmatter completion/due
    -- filtering, preserving the public tags() contract.
    local seen = {}
    add_tags(seen, tasks)
    if not tags_only then
        tasks = profile.measure("frontmatter.filter", frontmatter.filter_completed, tasks, ctx.fm_cfg)
        profile.measure("frontmatter.due", frontmatter.merge_due, tasks, ctx.fm_cfg, ctx.date_fmt, errors)
    end
    local project_tasks = {}
    for _, path in ipairs(projects) do
        async.checkpoint()
        local task = frontmatter.project_task(path, ctx.fm_cfg, ctx.date_fmt, errors)
        if task then
            tasks[#tasks + 1] = task
            project_tasks[#project_tasks + 1] = task
        end
    end
    add_tags(seen, project_tasks)
    return { tasks = tasks, tags = sorted_tags(seen), errors = errors }
end
build_tasks = profile.wrap("tasks.build", build_tasks)

local function render(ctx, data)
    if data.errors and #data.errors > 0 then
        local messages = {}
        for _, err in ipairs(data.errors) do
            async.checkpoint()
            messages[#messages + 1] = strftime.format_date_error(err)
        end
        return nil, table.concat(messages, "\n")
    end
    local view_key = vim.json.encode({ ctx.now, ctx.markers, ctx.ignore_undated, ctx.tags })
    if data.view_key == view_key then
        return data.text
    end
    local open = {}
    for _, task in ipairs(data.tasks) do
        async.checkpoint()
        if task.status == "open" then
            open[#open + 1] = task
        end
    end
    local text = profile.measure("format", format.format_taskfile, open, ctx.now, {
        markers = ctx.markers,
        ignore_undated = ctx.ignore_undated,
        tag_filter = ctx.tags,
        tag_prefix = ctx.tag_prefix,
        marker_prefix = ctx.marker_prefix,
        horizons = horizon.resolve(ctx.horizons, ctx.now, ctx.week_start, ctx.horizons_overlap),
        overlap = ctx.horizons_overlap,
        date_strftime = ctx.date_fmt,
    })
    data.view_key, data.text = view_key, text
    return text
end
render = profile.wrap("render", render)

local function new_context(opts)
    local config = require("taskbuffer.config").values
    return profile.measure("context", context.build_context, config, opts or {}), config
end

-- Discovery still runs on entry so newly added/deleted files are seen. If the
-- relevant file set and metadata are unchanged, parsing/frontmatter can be
-- skipped. Include ctime as well as mtime to catch restored modification times.
local function source_versions(matches, projects)
    local paths = {}
    for _, match in ipairs(matches) do
        async.checkpoint()
        paths[match.path] = paths[match.path] or false
    end
    for _, path in ipairs(projects) do
        paths[path] = true
    end
    local versions = {}
    for path, project in pairs(paths) do
        async.checkpoint()
        local stat = vim.uv.fs_stat(path)
        if not stat then
            return nil
        end -- file disappeared during discovery
        versions[path] = table.concat({
            tostring(project),
            stat.size,
            stat.ino,
            stat.mtime.sec,
            stat.mtime.nsec,
            stat.ctime.sec,
            stat.ctime.nsec,
        }, ":")
    end
    return versions
end

local function same_versions(a, b)
    if not a or not b then
        return false
    end
    for path, value in pairs(a) do
        async.checkpoint()
        if b[path] ~= value then
            return false
        end
    end
    for path in pairs(b) do
        async.checkpoint()
        if a[path] == nil then
            return false
        end
    end
    return true
end

-- Synchronous helpers remain available for scripts; interactive paths use the
-- async APIs below, including the very first open and tag picker.
function M.list(opts)
    local ctx = new_context(opts)
    local matches, err = scan.scan(ctx)
    if err then
        return nil, err
    end
    local projects, project_err = scan.scan_project_paths(ctx)
    if project_err then
        return nil, project_err
    end
    return render(ctx, build_tasks(ctx, matches, projects))
end

function M.tags(opts)
    local ctx = new_context(opts)
    local matches, err = scan.scan(ctx)
    if err then
        return {}, err
    end
    local projects, project_err = scan.scan_project_paths(ctx)
    if project_err then
        return {}, project_err
    end
    return build_tasks(ctx, matches, projects, true).tags
end

-- Both scans run concurrently; a failure aborts the whole operation. CPU work
-- starts only after both succeed. Cancellation owns subprocesses and all slices.
local function collect_async(ctx, tags_only, cb, previous)
    local remaining = 2
    local matches, projects
    local finished = false
    local cancel_scan, cancel_projects, cancel_build
    local function cancel()
        finished = true
        if cancel_scan then
            cancel_scan()
        end
        if cancel_projects then
            cancel_projects()
        end
        if cancel_build then
            cancel_build()
        end
    end
    local function ready(err)
        if finished then
            return
        end
        if err then
            cancel()
            cb(nil, err)
            return
        end
        remaining = remaining - 1
        if remaining == 0 then
            cancel_build = async.run(function()
                local versions = profile.measure("sources.check", source_versions, matches, projects)
                if previous and same_versions(versions, previous.versions) then
                    return previous
                end
                local data = build_tasks(ctx, matches, projects, tags_only)
                data.versions = versions
                return data
            end, function(data, failure)
                if not finished then
                    finished = true
                    cb(data, failure)
                end
            end)
        end
    end
    cancel_scan = scan.scan_async(ctx, function(value, err)
        matches = value
        ready(err)
    end)
    cancel_projects = scan.scan_project_paths_async(ctx, function(value, err)
        projects = value
        ready(err)
    end)
    return cancel
end

function M.list_async(opts, cb)
    opts = opts or {}
    local span = profile.begin("list.async.wall")
    local ctx, config = new_context(opts)
    local cancelled = false
    local cancel_collect, cancel_render
    local function finish(text, err)
        profile.finish(span)
        if not cancelled then
            cb(text, err)
        end
    end
    local function display(data, err)
        if err then
            finish(nil, err)
            return
        end
        cancel_render = async.run(function()
            return render(ctx, data)
        end, finish)
    end
    if opts.reuse and cached and cached.config == config then
        display(cached.data)
    else
        revision = revision + 1
        local version = revision
        local previous = not opts.force and cached and cached.config == config and cached.data or nil
        cancel_collect = collect_async(ctx, false, function(data, err)
            if not err and version == revision then
                cached = { config = config, data = data }
            end
            display(data, err)
        end, previous)
    end
    return function()
        cancelled = true
        if cancel_collect then
            cancel_collect()
        end
        if cancel_render then
            cancel_render()
        end
        profile.finish(span)
    end
end

function M.tags_async(opts, cb)
    local span = profile.begin("tags.async.wall")
    local ctx, config = new_context(opts)
    local function finish(tags, err)
        profile.finish(span)
        cb(tags, err)
    end
    if cached and cached.config == config then
        return async.run(function()
            return vim.list_slice(cached.data.tags)
        end, finish)
    end
    return collect_async(ctx, true, function(data, err)
        finish(data and data.tags, err)
    end)
end

M.list = profile.wrap("list.sync", M.list)
M.tags = profile.wrap("tags.sync", M.tags)
return M
