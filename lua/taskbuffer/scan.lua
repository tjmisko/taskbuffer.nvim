-- scan.lua — the search layer (port of go/scan.go).
--
-- Pipeline stage 1: shell out to ripgrep (or grep as a fallback) and return the
-- raw matched task lines as RawMatch records. Parsing those lines into Tasks is
-- the parse module's job; this module only finds them.
--
-- Output format (overview D4): plain NUL-delimited rather than --json. rg prints
-- one record per match as `<path>\0<lineno>:<text>\n`. The NUL after the path
-- means arbitrary `:` / unicode in the matched text parses unambiguously, and
-- the layout is ~10x cheaper to consume than vim.json.decode per line. grep
-- (`--null`) emits the same layout, so _parse_output is shared verbatim.
--
-- Default rg semantics are preserved for parity with the Go call: respects
-- .gitignore, skips hidden + binary files, does NOT follow symlinks (symlink
-- de-duplication is handled by deduplicate_paths, not by rg).

local uv = vim.uv or vim.loop
local profile = require("taskbuffer.profile")

local M = {}
local async = require("taskbuffer.async")

---@class RawMatch
---@field path string         absolute file path (rg/grep print abs paths because we pass abs sources)
---@field line_number integer 1-based
---@field text string         the matched line, WITHOUT trailing newline

-- Mirrors scan.go:22 `defaultScanPattern`. Matches any `- [.]` checkbox.
M.DEFAULT_PATTERN = [==[\- \[.\]]==]

-- Cached `vim.fn.executable("rg")` result. Tests may replace M._have_rg wholesale
-- to force the grep fallback path; the argv builders call it through the M table.
local rg_available = nil
function M._have_rg()
    if rg_available == nil then
        rg_available = vim.fn.executable("rg") == 1
    end
    return rg_available
end

-- ---------------------------------------------------------------------------
-- Path handling: glob expansion + symlink de-duplication
-- ---------------------------------------------------------------------------

--- Resolve symlinks, sort by length, and drop paths nested under another kept
--- path (e.g. /a and /a/b -> /a). Mirrors deduplicatePaths (scan.go:37-67).
---@param paths string[]
---@return string[]
function M.deduplicate_paths(paths)
    local resolved = {}
    for _, p in ipairs(paths or {}) do
        -- fs_realpath is the libuv analogue of Go's filepath.EvalSymlinks: both
        -- canonicalize AND fail on nonexistent paths. On failure keep the
        -- original so a nonexistent plain path still reaches rg (scan.go:43-44).
        local r = uv.fs_realpath(p)
        resolved[#resolved + 1] = r or p
    end

    table.sort(resolved, function(a, b)
        return #a < #b
    end)

    local kept = {}
    for _, p in ipairs(resolved) do
        local nested = false
        for _, k in ipairs(kept) do
            -- The k.."/" guard is load-bearing: it prevents /a/b from absorbing
            -- /a/bcd (mirrors strings.HasPrefix(p, k+"/") || p == k, scan.go:57).
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
--- Mirrors expandGlobs (scan.go:69-84).
---@param paths string[]
---@return string[]
function M.expand_globs(paths)
    local result = {}
    for _, p in ipairs(paths or {}) do
        -- Detect globs by `*`/`?` only, exactly like Go's ContainsAny(p, "*?")
        -- (scan.go:74). `[` is NOT a glob trigger, so `~/Notes/[a].md` passes
        -- through literally. In Lua patterns `*` and `?` are plain inside [].
        if p:find("[*?]") then
            -- nosuf=true, list=true; no-match yields {} (Go: filepath.Glob -> nil).
            local matched = vim.fn.glob(p, true, true)
            for _, m in ipairs(matched) do
                result[#result + 1] = m
            end
        else
            result[#result + 1] = p
        end
    end
    return M.deduplicate_paths(result)
end

-- ---------------------------------------------------------------------------
-- rg / grep argv contracts
-- ---------------------------------------------------------------------------

--- Build the argv for the matched-line scan.
---@param pattern string
---@param paths string[]
---@return string[]
local function build_scan_argv(pattern, paths, annotations)
    local argv
    if M._have_rg() then
        -- --no-config (D5): ignore a user's RIPGREP_CONFIG_PATH that could inject
        -- --heading/--color and corrupt the plain layout. --null/-n/--no-heading/
        -- --color=never pin a deterministic, machine-parseable record layout.
        argv =
            { "rg", "--no-config", "--color=never", "--no-heading", "--with-filename", "-n", "--null", "-e", pattern }
    else
        -- Use --null: macOS grep interprets -Z as decompression instead.
        -- grep fallback (rg absent). --null=NUL-after-path, -n=line numbers,
        -- -r=recursive WITHOUT following symlinks (matches rg default; -R follows),
        -- -E=ERE (the alternation pattern needs it), -I=skip binary.
        argv = { "grep", "-rnEHI", "--null", "--include=*.md", "-e", pattern }
        for _, rule in ipairs(annotations or {}) do
            argv[#argv + 1] = "--include=*." .. rule.extension
        end
    end
    argv[#argv + 1] = "--"
    vim.list_extend(argv, paths)
    return argv
end

--- Build the argv for the project-candidate scan (files-with-matches only).
---@param paths string[]
---@return string[]
local function build_project_argv(paths)
    local argv
    if M._have_rg() then
        argv = { "rg", "--no-config", "--color=never", "-l", "-e", "- project", "--glob", "*.md" }
    else
        argv = { "grep", "-rlEI", "--include=*.md", "-e", "- project" }
    end
    argv[#argv + 1] = "--"
    vim.list_extend(argv, paths)
    return argv
end

-- ---------------------------------------------------------------------------
-- Output parsing + exit-code classification
-- ---------------------------------------------------------------------------

--- Parse NUL-delimited rg/grep output into RawMatch records.
--- Each record is `<path>\0<lineno>:<text>` (gmatch already strips the trailing \n).
---@param stdout string|nil
---@return RawMatch[]
local function parse_output(stdout)
    local matches = {}
    if not stdout or stdout == "" then
        return matches
    end
    for record in stdout:gmatch("[^\n]+") do
        async.checkpoint()
        local nul = record:find("\0", 1, true)
        if nul then
            local path = record:sub(1, nul - 1)
            local rest = record:sub(nul + 1)
            -- Anchor the lineno; `.*` swallows the rest so inner `:` stays in text.
            local lineno, text = rest:match("^(%d+):(.*)$")
            if lineno then
                matches[#matches + 1] = {
                    path = path,
                    line_number = tonumber(lineno),
                    text = text,
                }
            end
        end
    end
    return matches
end

--- Map a scan process result onto (matches, err). Mirrors scan.go:141-153.
--- Exit 1 = no matches -> empty (not an error). Exit 2 with empty stderr = no
--- searchable files -> empty. Any other nonzero (incl. exit 2 WITH stderr, even
--- if some matches were printed) -> error, discarding matches (D6 abort-on-error).
---@param code integer
---@param stderr string|nil
---@param stdout string|nil
---@return RawMatch[]|nil matches, string|nil err
local function classify_exit(code, stderr, stdout)
    if code == 0 then
        return parse_output(stdout), nil
    end
    if code == 1 then
        return {}, nil
    end
    if code == 2 and (stderr == nil or stderr == "") then
        return {}, nil
    end
    return nil, "scan command exited with code " .. tostring(code) .. ": " .. (stderr or "")
end
classify_exit = profile.wrap("scan.decode", classify_exit)

-- Resolve the scan pattern from ctx, falling back to the default.
local function ctx_pattern(ctx)
    if ctx and type(ctx.scan_pattern) == "string" and ctx.scan_pattern ~= "" then
        return ctx.scan_pattern
    end
    return M.DEFAULT_PATTERN
end

local function ctx_sources(ctx)
    return (ctx and ctx.sources) or {}
end

-- ---------------------------------------------------------------------------
-- Public scan entry points
-- ---------------------------------------------------------------------------

--- Synchronous matched-line scan. Mirrors Scan() (scan.go:88-156).
---@param ctx table|nil  reads ctx.sources (string[]) and ctx.scan_pattern (string)
---@return RawMatch[]|nil matches, string|nil err
function M.scan(ctx)
    local paths = M.expand_globs(ctx_sources(ctx))
    if #paths == 0 then
        return {}, nil -- no rg invocation (scan.go:90-92)
    end
    local argv = build_scan_argv(ctx_pattern(ctx), paths, ctx and ctx.annotations)
    local span = profile.begin("scan.process.sync")
    local res = vim.system(argv, { text = true }):wait()
    profile.finish(span)
    return classify_exit(res.code, res.stderr, res.stdout)
end

--- Async matched-line scan. rg/grep runs off the UI loop; cb is invoked via
--- vim.schedule with (matches, err). Buffered, not streaming (D3).
---@param ctx table|nil
---@param cb fun(matches:RawMatch[]|nil, err:string|nil)
-- Both process execution and output decoding are cancellable. Spawn failures
-- use the same asynchronous error callback as nonzero process exits.
local function run_async(argv, decode, name, cb)
    local cancelled, process, decode_cancel = false, nil, nil
    local span = profile.begin(name)
    local function on_exit(res)
        profile.finish(span)
        local queued = profile.begin("scan.schedule_delay")
        decode_cancel = async.run(function()
            profile.finish(queued)
            return decode(res.code, res.stderr, res.stdout)
        end, function(value, err)
            if not cancelled then
                cb(value, err)
            end
        end)
        if cancelled then
            decode_cancel()
        end
    end
    local ok, result = pcall(vim.system, argv, { text = true }, on_exit)
    if ok then
        process = result
    else
        on_exit({ code = -1, stderr = tostring(result) })
    end
    return function()
        cancelled = true
        if decode_cancel then
            decode_cancel()
        end
        if process then
            pcall(process.kill, process, 15)
        end
    end
end

function M.scan_async(ctx, cb)
    local paths = M.expand_globs(ctx_sources(ctx))
    if #paths == 0 then
        return async.run(function()
            return {}
        end, cb)
    end
    return run_async(
        build_scan_argv(ctx_pattern(ctx), paths, ctx and ctx.annotations),
        classify_exit,
        "scan.process.async",
        cb
    )
end

--- Find markdown files whose content contains a `- project` line (the project
--- frontmatter tag). Returns candidate file paths only; turning them into Tasks
--- (frontmatter parse + due/status filtering) is the frontmatter module's job.
--- Mirrors the rg invocation of ScanProjects (scan.go:158-176).
---
--- NOTE the asymmetry with scan(): ScanProjects does NOT special-case exit 2.
--- Only exit 1 -> empty; every other nonzero -> error (scan.go:170-176).
---@param ctx table|nil  reads ctx.sources
---@return string[]|nil files, string|nil err
local function classify_projects(code, stderr, stdout)
    if code == 1 then
        return {}, nil
    end
    if code ~= 0 then
        return nil, "project scan exited with code " .. tostring(code) .. ": " .. (stderr or "")
    end
    local files = {}
    for line in (stdout or ""):gmatch("[^\n]+") do
        async.checkpoint()
        local file = vim.trim(line)
        if file ~= "" then
            files[#files + 1] = file
        end
    end
    return files, nil
end

function M.scan_project_paths(ctx)
    local paths = M.expand_globs(ctx_sources(ctx))
    if #paths == 0 then
        return {}, nil
    end
    local result = vim.system(build_project_argv(paths), { text = true }):wait()
    return classify_projects(result.code, result.stderr, result.stdout)
end

function M.scan_project_paths_async(ctx, cb)
    local paths = M.expand_globs(ctx_sources(ctx))
    if #paths == 0 then
        return async.run(function()
            return {}
        end, cb)
    end
    return run_async(build_project_argv(paths), classify_projects, "scan.projects.async", cb)
end

-- ---------------------------------------------------------------------------
-- Pattern construction (overview D1: lives here so the escaping stays next to
-- the rg/grep concern; the integrator may call this to populate ctx.scan_pattern)
-- ---------------------------------------------------------------------------

-- Chars escaped by Go's regexp.QuoteMeta (specialBytes), plus backslash itself.
-- Used so configured checkbox literals become valid rg-regex / grep-ERE literals.
local QUOTE_META = "\\.+*?()|[]{}^$"

local function rg_quote_meta(s)
    return (
        s:gsub(".", function(c)
            if QUOTE_META:find(c, 1, true) then
                return "\\" .. c
            end
            return c
        end)
    )
end

--- Build an rg alternation pattern from configured checkbox literals.
--- Mirrors parse.go:107-118 (and the longest-first sort at parse.go:170-176).
--- Empty/whitespace-only config -> DEFAULT_PATTERN.
---@param checkbox table<string,string>|nil  status_name -> checkbox literal
---@return string
function M.build_pattern(checkbox)
    if not checkbox or next(checkbox) == nil then
        return M.DEFAULT_PATTERN
    end
    local seen, parts = {}, {}
    for _, cb in pairs(checkbox) do
        cb = vim.trim(cb)
        if cb ~= "" then
            local esc = rg_quote_meta(cb)
            if not seen[esc] then
                seen[esc] = true
                parts[#parts + 1] = esc
            end
        end
    end
    if #parts == 0 then
        return M.DEFAULT_PATTERN
    end
    table.sort(parts, function(a, b)
        if #a ~= #b then
            return #a > #b -- longest first, so longer literals win the alternation
        end
        return a < b -- ties broken alphabetically ascending (parse.go:170-176)
    end)
    return table.concat(parts, "|")
end

M.expand_globs = profile.wrap("scan.paths", M.expand_globs)
M.scan = profile.wrap("scan.sync", M.scan)
M.scan_async = profile.wrap("scan.async.dispatch", M.scan_async)
M.scan_project_paths = profile.wrap("scan.projects.sync", M.scan_project_paths)

return M
