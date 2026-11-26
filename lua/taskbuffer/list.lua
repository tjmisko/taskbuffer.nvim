-- Render task lists from the in-memory index (index.lua). Display options reuse
-- the latest snapshot; entering taskbuffer or mutating a source sweeps the index.
local context = require("taskbuffer.context")
local index = require("taskbuffer.index")
local horizon = require("taskbuffer.horizon")
local format = require("taskbuffer.format")
local strftime = require("taskbuffer.strftime")
local profile = require("taskbuffer.profile")
local async = require("taskbuffer.async")

local M = {}

--- Drop the index entirely (configuration changed).
function M.invalidate()
    index.reset()
end

local function render(ctx, data, view)
    if data.errors and #data.errors > 0 then
        local messages = {}
        for _, err in ipairs(data.errors) do
            async.checkpoint()
            messages[#messages + 1] = strftime.format_date_error(err)
        end
        return nil, table.concat(messages, "\n")
    end
    local view_key = vim.json.encode({ ctx.now, ctx.markers, ctx.ignore_undated, ctx.tags, view == true })
    if data.view_key == view_key then
        return data.rendered
    end
    local open = {}
    for _, task in ipairs(data.tasks) do
        async.checkpoint()
        if task.status == "open" then
            open[#open + 1] = task
        end
    end
    local output = profile.measure("format", view and format.format_view or format.format_taskfile, open, ctx.now, {
        markers = ctx.markers,
        ignore_undated = ctx.ignore_undated,
        tag_filter = ctx.tags,
        tag_prefix = ctx.tag_prefix,
        marker_prefix = ctx.marker_prefix,
        horizons = horizon.resolve(ctx.horizons, ctx.now, ctx.week_start, ctx.horizons_overlap),
        overlap = ctx.horizons_overlap,
        date_strftime = ctx.date_fmt,
    })
    data.view_key, data.rendered = view_key, output
    return output
end
render = profile.wrap("render", render)

local function new_context(opts)
    local config = require("taskbuffer.config").values
    return profile.measure("context", context.build_context, config, opts or {}), config
end

-- Synchronous helpers remain available for scripts; they sweep the index (walk,
-- stat, reparse changed files) so they always see the current disk state.
function M.list(opts)
    local ctx = new_context(opts)
    local data, err = index.refresh_sync(ctx)
    if err then
        return nil, err
    end
    return render(ctx, data)
end

function M.tags(opts)
    local ctx = new_context(opts)
    local data, err = index.refresh_sync(ctx)
    if err then
        return {}, err
    end
    return vim.list_slice(data.tags)
end

-- A reused view renders from the index as it is; anything else sweeps first.
-- Both run in cancellable slices and share the index with every other caller.
local function snapshot_async(ctx, reuse, cb)
    if reuse and index.is_ready() then
        return async.run(function()
            return index.current()
        end, cb)
    end
    return index.refresh_async(ctx, cb)
end

function M.list_async(opts, cb)
    opts = opts or {}
    local span = profile.begin("list.async.wall")
    local ctx = new_context(opts)
    local cancelled = false
    local cancel_collect, cancel_render
    local function finish(text, err, data)
        profile.finish(span)
        if not cancelled then
            cb(text, err, data)
        end
    end
    cancel_collect = snapshot_async(ctx, opts.reuse, function(data, err)
        if err then
            finish(nil, err)
            return
        end
        cancel_render = async.run(function()
            return render(ctx, data, opts.view)
        end, function(text, failure)
            finish(text, failure, data)
        end)
    end)
    return function()
        cancelled = true
        cancel_collect()
        if cancel_render then
            cancel_render()
        end
        profile.finish(span)
    end
end

-- Interactive consumers receive visible lines and row metadata together.
function M.view_async(opts, cb)
    return M.list_async(vim.tbl_extend("force", opts or {}, { view = true }), cb)
end

-- Synchronous render of the current index for an action that just changed it.
-- Never sweeps unless no index exists yet. Returns view, err, data.
function M.view_sync(opts)
    opts = vim.tbl_extend("force", opts or {}, { view = true })
    local ctx = new_context(opts)
    local data, err
    if index.is_ready() then
        data = index.current()
    else
        data, err = index.refresh_sync(ctx)
    end
    if err then
        return nil, err
    end
    local view, render_err = render(ctx, data, true)
    return view, render_err, data
end

function M.tags_async(opts, cb)
    local span = profile.begin("tags.async.wall")
    local ctx = new_context(opts)
    return snapshot_async(ctx, index.is_ready(), function(data, err)
        profile.finish(span)
        cb(data and vim.list_slice(data.tags), err)
    end)
end

M.list = profile.wrap("list.sync", M.list)
M.tags = profile.wrap("tags.sync", M.tags)
return M
