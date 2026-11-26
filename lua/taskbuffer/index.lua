-- index.lua: the in-memory task index.
--
-- files[path] = { version, all, tasks, project, originals, annotations, errors }
--   version     source.version(path) when the file was read
--   all         parsed tasks with frontmatter tags merged (tag queries)
--   tasks       `all` minus completed-frontmatter tasks, with inherited due dates
--   project     synthetic project task from frontmatter, or nil
--   originals   line_number -> original line text (for stale-location checks)
--   annotations line_number -> true for code annotation tasks
--   errors      strict-mode date errors found in this file, or nil
--
-- Discovery (walk.lua) and parsing share one pass that works synchronously or
-- inside an async.run slice (async.checkpoint yields only inside a job). A pass
-- re-stats every walked file and reparses only those whose version changed, so
-- the first build and every later sweep are the same code.

local uv = vim.uv or vim.loop
local async = require("taskbuffer.async")
local profile = require("taskbuffer.profile")
local walk = require("taskbuffer.walk")
local parse = require("taskbuffer.parse")
local frontmatter = require("taskbuffer.frontmatter")
local source = require("taskbuffer.source")

local M = {}

M.RESET_ERROR = "task index was reset"

---@class TaskIndexState
---@field key string fingerprint of the configuration the files were parsed with
---@field ctx table parse context
---@field files table<string, table>
---@field revision integer bumped whenever any file entry changes
---@field ready boolean a complete pass has finished
---@field roots string[]
---@field snapshot table|nil
local state

local function fingerprint(config)
    return vim.json.encode({
        config.sources,
        config.exclude,
        config.annotations,
        config.formats,
        config.strict,
        config.frontmatter,
    })
end

--- Drop the whole index (configuration changes, tests).
function M.reset()
    state = nil
end

---@return boolean
function M.is_ready()
    return state ~= nil and state.ready
end

---@return integer
function M.revision()
    return state and state.revision or 0
end

---@return string[]
function M.paths()
    local paths = {}
    for path in pairs(state and state.files or {}) do
        paths[#paths + 1] = path
    end
    table.sort(paths)
    return paths
end

---@param path string
---@return table|nil
function M.entry(path)
    return state and state.files[path] or nil
end

local function state_for(ctx)
    local config = require("taskbuffer.config").values
    local key = fingerprint(config)
    if state and state.key == key then
        return state
    end
    state = { key = key, ctx = ctx, files = {}, revision = 0, ready = false, roots = {} }
    return state
end

local function bump(st)
    st.revision = st.revision + 1
    st.snapshot = nil
end

local function read_file(path)
    local fd = uv.fs_open(path, "r", 438)
    if not fd then
        return nil
    end
    local stat = uv.fs_fstat(fd)
    local data = stat and uv.fs_read(fd, stat.size, 0) or nil
    uv.fs_close(fd)
    return data
end

local function first_bytes(ctx)
    if ctx.index_first_bytes then
        return ctx.index_first_bytes
    end
    local set = {}
    for _, checkbox in ipairs(ctx.checkboxes) do
        set[checkbox:byte(1)] = true
    end
    ctx.index_first_bytes = set
    return set
end

local function annotation_extensions(ctx)
    local set = {}
    for _, rule in ipairs(ctx.annotations or {}) do
        set[rule.extension] = true
    end
    return set
end

local function empty_entry(version)
    return { version = version, all = {}, tasks = {}, originals = {}, annotations = {}, errors = nil }
end

--- Parse one file's contents into an index entry. O(file size).
---@param path string
---@param data string
---@param ctx table pipeline context (checkboxes, formats, fm_cfg, ...)
---@param version string|nil
---@return table entry
function M.parse_file(path, data, ctx, version)
    local entry = empty_entry(version)
    if walk.is_binary(data) then
        return entry
    end
    local errors = ctx.strict and {} or nil
    entry.errors = errors
    local pctx = setmetatable({ date_errors = errors }, { __index = ctx })
    local extension = path:match("%.([^./]+)$")
    local scan_every_line = extension ~= nil and annotation_extensions(ctx)[extension] == true
    local starts = first_bytes(ctx)
    local tasks = {}
    local position, size, line_number = 1, #data, 0
    while position <= size do
        local newline = data:find("\n", position, true)
        local last = newline and newline - 1 or size
        line_number = line_number + 1
        local first = data:find("[^ \t]", position)
        if first and first <= last and (scan_every_line or starts[data:byte(first)]) then
            async.checkpoint()
            local text = data:sub(position, last)
            local task = parse.parse_task({ path = path, line_number = line_number, text = text }, pctx)
            if task then
                tasks[#tasks + 1] = task
                entry.originals[line_number] = (text:gsub("\r$", ""))
                if task.annotation then
                    entry.annotations[line_number] = true
                end
            end
        end
        position = last + 2
    end
    local project_candidate = extension == "md" and data:find("- project", 1, true) ~= nil
    if #tasks == 0 and not project_candidate then
        return entry
    end
    frontmatter.parse_frontmatter_data(path, data)
    frontmatter.merge_tags(tasks)
    entry.all = tasks
    entry.tasks = frontmatter.filter_completed(tasks, ctx.fm_cfg)
    frontmatter.merge_due(entry.tasks, ctx.fm_cfg, ctx.date_fmt, errors)
    if project_candidate then
        entry.project = frontmatter.project_task(path, ctx.fm_cfg, ctx.date_fmt, errors)
    end
    frontmatter.invalidate(path)
    return entry
end
M.parse_file = profile.wrap("index.parse_file", M.parse_file)

-- One discovery + reparse pass. Returns an error string or nil.
local function refresh(st)
    local files, err, roots = walk.walk(st.ctx)
    if not files then
        return err
    end
    st.roots = roots
    local seen = {}
    for _, path in ipairs(files) do
        async.checkpoint()
        if state ~= st then
            return M.RESET_ERROR
        end
        seen[path] = true
        local version = source.version(path)
        local existing = st.files[path]
        if not version then
            if existing then
                st.files[path] = nil
                bump(st)
            end
            seen[path] = nil
        elseif not existing or existing.version ~= version then
            local data = read_file(path)
            st.files[path] = data and M.parse_file(path, data, st.ctx, version) or empty_entry(version)
            bump(st)
        end
    end
    for path in pairs(st.files) do
        if not seen[path] then
            st.files[path] = nil
            bump(st)
        end
    end
    st.ready = true
    return nil
end
refresh = profile.wrap("index.refresh", refresh)

--- Resolve a path the way discovery spells it.
local function canonical(path)
    return uv.fs_realpath(path) or path
end

--- Is this path one the index covers (indexed already, or inside a source)?
---@param path string
---@return boolean
function M.accepts(path)
    if not state then
        return false
    end
    path = canonical(path)
    if state.files[path] then
        return true
    end
    for _, root in ipairs(state.roots) do
        if path == root or walk.accepts_below(path, root, state.ctx) then
            return true
        end
    end
    return false
end

--- Synchronously reparse one file from in-memory contents. data == nil removes it.
---@param path string
---@param data string|nil
---@param version string|nil defaults to the file's current on-disk version
---@return boolean updated false when no index exists
function M.update_file(path, data, version)
    local st = state
    if not st then
        return false
    end
    path = canonical(path)
    if data == nil then
        if st.files[path] then
            st.files[path] = nil
            bump(st)
        end
        return true
    end
    st.files[path] = M.parse_file(path, data, st.ctx, version or source.version(path))
    bump(st)
    return true
end

--- Reread one file from disk (BufWritePost) and reparse it.
---@param path string
---@return boolean
function M.update_file_from_disk(path)
    if not state then
        return false
    end
    path = canonical(path)
    local version = source.version(path)
    local data = version and read_file(path) or nil
    return M.update_file(path, data, version)
end

--- Immutable-by-convention view of the index consumed by list.lua.
---@param st TaskIndexState|nil
---@return table data
function M.snapshot(st)
    st = st or state
    if st.snapshot then
        return st.snapshot
    end
    local revision = st.revision
    local paths = {}
    for path in pairs(st.files) do
        paths[#paths + 1] = path
    end
    async.sort(paths, function(a, b)
        return a < b
    end)
    local data = { tasks = {}, originals = {}, annotations = {}, versions = {}, errors = st.ctx.strict and {} or nil }
    local seen = {}
    local function add_tags(tasks, open_only)
        for _, task in ipairs(tasks) do
            if not open_only or task.status == "open" then
                for _, tag in ipairs(task.tags or {}) do
                    seen[tag] = true
                end
            end
        end
    end
    local projects = {}
    for _, path in ipairs(paths) do
        async.checkpoint()
        local entry = st.files[path]
        data.versions[path] = entry.version
        vim.list_extend(data.tasks, entry.tasks)
        if next(entry.originals) then
            data.originals[path] = entry.originals
        end
        if next(entry.annotations) then
            data.annotations[path] = entry.annotations
        end
        add_tags(entry.all, true)
        if entry.project then
            projects[#projects + 1] = entry.project
        end
        if data.errors and entry.errors then
            vim.list_extend(data.errors, entry.errors)
        end
    end
    for _, task in ipairs(projects) do
        data.tasks[#data.tasks + 1] = task
    end
    add_tags(projects, false)
    local tags = {}
    for tag in pairs(seen) do
        tags[#tags + 1] = tag
    end
    async.sort(tags, function(a, b)
        return a < b
    end)
    data.tags = tags
    data.revision = revision
    if st == state and st.revision == revision then
        st.snapshot = data
    end
    return data
end

--- Synchronously walk, reparse changed files, and return the snapshot.
---@param ctx table
---@return table|nil data
---@return string|nil err
function M.refresh_sync(ctx)
    local st = state_for(ctx)
    local err = refresh(st)
    if err then
        return nil, err
    end
    return M.snapshot(st)
end

--- Same as refresh_sync inside async slices. Returns a cancel function.
---@param ctx table
---@param cb fun(data: table|nil, err: string|nil)
---@return fun()
function M.refresh_async(ctx, cb)
    local st = state_for(ctx)
    return async.run(function()
        local err = refresh(st)
        if err then
            return nil, err
        end
        return M.snapshot(st)
    end, cb)
end

--- Snapshot of the current index without touching the disk, or nil if unbuilt.
---@return table|nil
function M.current()
    if not state or not state.ready then
        return nil
    end
    return M.snapshot(state)
end

return M
