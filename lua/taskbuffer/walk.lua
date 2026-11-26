-- walk.lua: pure-Lua source discovery.
--
-- Expands configured sources (globs, files, directories) and recursively lists
-- the files worth indexing. No subprocesses. async.checkpoint() calls make the
-- same code usable synchronously and inside an async.run slice.

local uv = vim.uv or vim.loop
local async = require("taskbuffer.async")
local profile = require("taskbuffer.profile")

local M = {}

M.DEFAULT_EXCLUDE = { "node_modules", "target", "dist", "build" }

--- Resolve symlinks, sort by length, and drop paths nested under another kept
--- path (e.g. /a and /a/b -> /a).
---@param paths string[]
---@return string[]
function M.deduplicate_paths(paths)
    local resolved = {}
    for _, p in ipairs(paths or {}) do
        -- On failure keep the original so a nonexistent plain path still
        -- surfaces as an error from walk().
        resolved[#resolved + 1] = uv.fs_realpath(p) or p
    end

    table.sort(resolved, function(a, b)
        return #a < #b
    end)

    local kept = {}
    for _, p in ipairs(resolved) do
        local nested = false
        for _, k in ipairs(kept) do
            -- The k.."/" guard keeps /a/b from absorbing /a/bcd.
            if p == k or p:sub(1, #k + 1) == (k .. "/") then
                nested = true
                break
            end
        end
        if not nested then
            kept[#kept + 1] = p
        end
    end
    return kept
end

--- Expand glob patterns, pass plain paths through, and dedup the union.
--- Globs are detected by `*`/`?` only, so `[a].md` passes through literally.
---@param paths string[]
---@return string[]
function M.expand_globs(paths)
    local result = {}
    for _, p in ipairs(paths or {}) do
        if p:find("[*?]") then
            for _, matched in ipairs(vim.fn.glob(p, true, true)) do
                result[#result + 1] = matched
            end
        else
            result[#result + 1] = p
        end
    end
    return M.deduplicate_paths(result)
end

local function extension_of(name)
    return name:match("%.([^./]+)$")
end

--- Set of file extensions (without dot) the walk keeps while recursing.
---@param ctx table|nil
---@return table<string, true>
function M.indexed_extensions(ctx)
    local extensions = { md = true }
    for _, rule in ipairs((ctx and ctx.annotations) or {}) do
        if type(rule.extension) == "string" then
            extensions[rule.extension] = true
        end
    end
    return extensions
end

local function exclude_set(ctx)
    local names = ctx and ctx.exclude
    if names == nil then
        names = M.DEFAULT_EXCLUDE
    end
    local set = {}
    for _, name in ipairs(names) do
        set[name] = true
    end
    return set
end

--- True when the first 8 KiB of contents contain a NUL byte.
---@param data string
---@return boolean
function M.is_binary(data)
    return data:sub(1, 8192):find("\0", 1, true) ~= nil
end

--- Would a file found while recursing under a source be indexed?
--- Applies the hidden-name and extension rules to every component below root.
---@param path string
---@param root string
---@param ctx table|nil
---@return boolean
function M.accepts_below(path, root, ctx)
    if path:sub(1, #root + 1) ~= root .. "/" then
        return false
    end
    local excluded = exclude_set(ctx)
    local parts = vim.split(path:sub(#root + 2), "/", { plain = true })
    for i, part in ipairs(parts) do
        if part:sub(1, 1) == "." then
            return false
        end
        if i < #parts and excluded[part] then
            return false
        end
    end
    local extension = extension_of(parts[#parts])
    return extension ~= nil and M.indexed_extensions(ctx)[extension] == true
end

--- Discover the files to index.
---@param ctx table|nil reads ctx.sources, ctx.exclude, ctx.annotations
---@return string[]|nil files sorted absolute paths
---@return string|nil err
---@return string[]|nil roots expanded source paths (directories and files)
function M.walk(ctx)
    local roots = M.expand_globs((ctx and ctx.sources) or {})
    local extensions = M.indexed_extensions(ctx)
    local excluded = exclude_set(ctx)
    local files, seen = {}, {}
    local function add(path)
        if not seen[path] then
            seen[path] = true
            files[#files + 1] = path
        end
    end
    for _, root in ipairs(roots) do
        local stat = uv.fs_stat(root)
        if not stat then
            return nil, "source not found: " .. root
        end
        if stat.type == "file" then
            add(root)
        elseif stat.type == "directory" then
            local pending = { root }
            while #pending > 0 do
                local directory = table.remove(pending)
                local handle = uv.fs_scandir(directory)
                if handle then
                    while true do
                        async.checkpoint()
                        local name, kind = uv.fs_scandir_next(handle)
                        if not name then
                            break
                        end
                        local full = directory .. "/" .. name
                        if kind == nil or kind == "unknown" then
                            local entry = uv.fs_lstat(full)
                            kind = entry and entry.type or nil
                        end
                        -- Hidden entries and symlinks found while recursing are skipped.
                        if name:sub(1, 1) ~= "." then
                            if kind == "directory" then
                                if not excluded[name] then
                                    pending[#pending + 1] = full
                                end
                            elseif kind == "file" then
                                local extension = extension_of(name)
                                if extension and extensions[extension] then
                                    add(full)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(files)
    return files, nil, roots
end
M.walk = profile.wrap("walk", M.walk)

return M
