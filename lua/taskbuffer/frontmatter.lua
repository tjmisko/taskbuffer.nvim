-- frontmatter.lua — the YAML-frontmatter read path (port of go/frontmatter.go
-- plus the FM-reading half of go/scan.go:ScanProjects).
--
-- Owns: a targeted YAML-subset head parser, a per-file cache (cleared once per
-- refresh), the key accessors, and the four pipeline operations
--   merge_tags -> filter_completed -> merge_due   (order is load-bearing)
-- plus project_task (synthetic SortLast task for `:Tasks` project scanning).
--
-- We do NOT depend on a YAML library (blueprint 03 §5.A). Instead a line scanner
-- recognizes two value KINDS: scalar string and list (block or inline-flow).
-- See blueprint docs/rewrite/03-frontmatter.md for the full rationale; the
-- output is identical to the Go yaml.v3 path on every fixture (§5.B).

local strftime = require("taskbuffer.strftime")

local M = {}

-- ── per-refresh cache (blueprint §3, overview §3.4) ───────────────────────────
-- path -> Frontmatter table, or `false` to memoize "no usable FM here".
-- Single-threaded → plain table, no lock. Cleared at refresh start via reset().
local cache = {}

-- ── small string helpers ─────────────────────────────────────────────────────

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Strip one matching pair of surrounding quotes. Returns value, was_quoted.
-- Shared shape with util.find_frontmatter_due_line (blueprint §5.D / D3).
local function unquote(s)
    if #s >= 2 then
        local first = s:sub(1, 1)
        local last = s:sub(-1)
        if (first == '"' and last == '"') or (first == "'" and last == "'") then
            return s:sub(2, -2), true
        end
    end
    return s, false
end

-- YAML strips a `# comment` that is preceded by whitespace (or at line start),
-- but never inside quotes. We only apply this to UNQUOTED scalars. Low priority:
-- no fixture exercises inline comments (blueprint §5.C).
local function strip_trailing_comment(v)
    local idx = v:find("%s#")
    if idx then
        return (v:sub(1, idx - 1):gsub("%s*$", ""))
    end
    return v
end

-- Parity guard (blueprint D5): yaml.v3 auto-resolves bare date-like scalars to
-- time.Time and reformats them (zero-padding 2026-4-1 -> 2026-04-01, dropping
-- seconds from 14:30:00 -> 14:30). Our raw read does not, so the downstream
-- strftime matcher (which expects %d%d-%d%d-%d%d) would miss a non-padded date.
-- Applied ONLY to unquoted scalars matching ^%d+-%d+-%d+, mirroring yaml.v3.
-- (RFC3339 T/Z forms are NOT handled — no fixture uses them; see report.)
local function normalize_bare_date(v)
    local y, mo, d, rest = v:match("^(%d+)%-(%d+)%-(%d+)(.*)$")
    if not y then
        return v
    end
    local date = string.format("%04d-%02d-%02d", tonumber(y), tonumber(mo), tonumber(d))
    local hh, mm = rest:match("^[ ](%d%d?):(%d%d)")
    if hh then
        return date .. " " .. string.format("%02d:%02d", tonumber(hh), tonumber(mm))
    end
    return date
end

-- "[a, b, c]" -> {"a","b","c"}; "[]" -> {}. Trims + unquotes each item.
-- Does not split commas inside quoted items (no fixture needs it; see report).
local function parse_flow_list(s)
    local inner = trim(s:sub(2, -2))
    local out = {}
    if inner == "" then
        return out
    end
    for item in (inner .. ","):gmatch("(.-),") do
        item = trim(item)
        if item ~= "" then
            out[#out + 1] = (unquote(item))
        end
    end
    return out
end

-- A block-list item ("  - work") -> its value (unquoted, comment-stripped).
local function list_item_value(item)
    local v, quoted = unquote(item)
    if not quoted then
        v = strip_trailing_comment(v)
    end
    return v
end

-- Store a "key: value" into fields, classifying the value kind. Returns the key
-- to "arm" as a pending block-list (when the value is empty), else nil.
local function classify_and_store(fields, key, val)
    if val == "" then
        -- Could be a block list ("tags:\n  - a"). Arm it; stays {} if nothing follows.
        fields[key] = {}
        return key
    end
    local first = val:sub(1, 1)
    if first == '"' or first == "'" then
        fields[key] = (unquote(val))
        return nil
    end
    if val:match("^%[.*%]$") then
        fields[key] = parse_flow_list(val)
        return nil
    end
    -- Unquoted scalar.
    val = strip_trailing_comment(val)
    val = normalize_bare_date(val)
    fields[key] = val
    return nil
end

-- ── the mini-parser (parity: parseFrontmatterFromFile, frontmatter.go:122) ─────
-- Reads ONLY the head (stops at the closing ---). Returns a Frontmatter table
-- { fields = <top-level map>, tags = <string[]>, lines = <key->1-based line> }
-- or nil when there is no usable frontmatter.
local function parse_head(path)
    local f = io.open(path, "r")
    if not f then
        return nil -- Go returns err; we treat unreadable as no-FM.
    end

    local first = f:read("*l")
    if first == nil or trim(first) ~= "---" then
        f:close()
        return nil -- no frontmatter (frontmatter.go:132)
    end

    local fields = {}
    local lines = {}
    local pending_list_key = nil
    local any = false
    local ln = 1 -- opening --- consumed

    while true do
        local line = f:read("*l")
        if line == nil then
            break -- EOF before closing --- → treat collected body as the FM
        end
        ln = ln + 1
        local stripped = trim(line)
        if stripped == "---" then
            break -- closing delimiter
        elseif stripped ~= "" then
            local item = line:match("^%s+%-%s+(.*)$")
            if pending_list_key and item ~= nil then
                local lst = fields[pending_list_key]
                lst[#lst + 1] = list_item_value(item)
            else
                pending_list_key = nil
                -- Top-level "key: value" (zero indentation; key has no colon).
                local key, val = line:match("^(%S[^:]*):%s*(.-)%s*$")
                if key ~= nil then
                    any = true
                    lines[key] = ln
                    pending_list_key = classify_and_store(fields, key, val)
                end
            end
        end
        -- blank line: ignore, leave any pending block-list armed
    end
    f:close()

    if not any then
        return nil -- empty FM (frontmatter.go:148)
    end

    -- tags: ONLY when the value parsed as a list (Go uses []interface{} only;
    -- a tags-as-string scalar is ignored).
    local tags = {}
    if type(fields["tags"]) == "table" then
        tags = fields["tags"]
    end

    return { fields = fields, tags = tags, lines = lines }
end

-- ── cache / lifecycle (parity: frontmatter.go:81-120) ─────────────────────────

--- Read and cache the frontmatter head of a markdown file.
--- Cached per path; nil means no/empty/unusable frontmatter.
---@param path string
---@return table|nil fm  -- { fields=<map>, tags=<string[]>, lines=<map> }
function M.parse_frontmatter(path)
    local cached = cache[path]
    if cached ~= nil then
        return cached or nil -- `false` memoizes "none"
    end
    local fm = parse_head(path)
    cache[path] = fm or false
    return fm
end
-- Blueprint-03 alias (Scan/CONTEXT references frontmatter.read).
M.read = M.parse_frontmatter

--- Clear the whole cache. Called once at the START of every refresh
--- (== ResetFrontmatterCache). Integration relies on this for fresh reads.
function M.reset()
    cache = {}
end

--- Drop a single cache entry (belt-and-suspenders for write helpers, §5.D).
---@param path string
function M.invalidate(path)
    cache[path] = nil
end

-- ── key accessors (parity: GetString :24, GetStringSlice :52) ─────────────────

--- Scalar value for a key; "" when absent / non-scalar (list).
---@param fm table|nil
---@param key string
---@return string
function M.get_string(fm, key)
    if not fm or not fm.fields then
        return ""
    end
    local v = fm.fields[key]
    if type(v) == "string" then
        return v
    end
    return ""
end

--- List value for a key; {} when absent / non-list.
---@param fm table|nil
---@param key string
---@return string[]
function M.get_string_slice(fm, key)
    if not fm or not fm.fields then
        return {}
    end
    local v = fm.fields[key]
    if type(v) == "table" then
        return v
    end
    return {}
end

--- Tags for a file (== ParseFrontmatterTags, frontmatter.go:104).
---@param path string
---@return string[]
function M.tags(path)
    local fm = M.parse_frontmatter(path)
    if not fm then
        return {}
    end
    return fm.tags
end

-- ── resolved-config helper (parity: main.go:42-77) ───────────────────────────
-- Adapts BOTH the nested live config shape ({due_key, inherit_due, require_tags,
-- status={key, done_values}}) AND a partial flat/Go-style config. Idempotent on
-- an already-resolved flat config, so callers may pass any of the three.
---@param c table|nil
---@return table  -- { due_key, status_key, done_values, inherit_due, require_tags }
function M.resolve_cfg(c)
    c = c or {}

    local status_key = c.status_key
    local done_values = c.done_values
    if c.status then
        status_key = status_key or c.status.key
        done_values = done_values or c.status.done_values
    end

    local function nonempty_str(s, default)
        if type(s) == "string" and s ~= "" then
            return s
        end
        return default
    end

    return {
        due_key = nonempty_str(c.due_key, "due"),
        status_key = nonempty_str(status_key, "status"),
        done_values = (type(done_values) == "table" and #done_values > 0) and done_values or { "done", "complete" },
        inherit_due = (c.inherit_due ~= false), -- *bool semantics: default true
        require_tags = c.require_tags or {},
    }
end

-- Split on the FIRST space (parity: strings.SplitN(due, " ", 2)).
local function split_first_space(s)
    local sp = s:find(" ", 1, true)
    if sp then
        return s:sub(1, sp - 1), s:sub(sp + 1)
    end
    return s, nil
end

-- Build a lowercased set from a list of done values.
local function lower_set(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v:lower()] = true
    end
    return set
end

-- Parse + strictly validate a frontmatter date string into a noon epoch.
-- Returns epoch|nil. On failure (format mismatch OR calendar-invalid), emits a
-- DateError into `date_errors` (when non-nil) using `context`.
local function parse_due_date(date_str, spec, path, context, date_errors)
    local y, mo, d = strftime.components(date_str, spec)
    if y == nil then
        strftime.collect_date_error(
            date_errors,
            strftime.new_date_error(path, 0, date_str, context, "does not match date format")
        )
        return nil
    end
    local ok, reason = strftime.validate_date(y, mo, d)
    if not ok then
        strftime.collect_date_error(date_errors, strftime.new_date_error(path, 0, date_str, context, reason))
        return nil
    end
    return strftime.date_to_epoch(y, mo, d)
end

-- ── pipeline op 1: merge_tags (parity: frontmatter.go:176-193) ────────────────

--- Union each file's frontmatter tags into the task's tags (dedup, FM tags
--- appended after inline tags, order preserved). Mutates in place.
---@param tasks table[]
function M.merge_tags(tasks)
    for _, task in ipairs(tasks) do
        local fm = M.parse_frontmatter(task.file_path)
        if fm and #fm.tags > 0 then
            task.tags = task.tags or {}
            local existing = {}
            for _, t in ipairs(task.tags) do
                existing[t] = true
            end
            for _, t in ipairs(fm.tags) do
                if not existing[t] then
                    task.tags[#task.tags + 1] = t
                    existing[t] = true
                end
            end
        end
    end
end
M.merge_frontmatter_tags = M.merge_tags -- blueprint-03 alias

-- ── pipeline op 2: filter_completed (parity: frontmatter.go:258-304) ──────────
-- MUST run BEFORE merge_due. Only drops tasks whose due_date == nil; if inherit
-- ran first every undated task in a done file would acquire a date and survive.

--- Drop undated tasks whose file frontmatter is "done" (has a due AND a status
--- in done_values). Returns a NEW list.
---@param tasks table[]
---@param fm_cfg table|nil
---@return table[]
function M.filter_completed(tasks, fm_cfg)
    local cfg = M.resolve_cfg(fm_cfg)
    if #cfg.done_values == 0 then
        return tasks -- guard (effectively dead; resolve_cfg supplies defaults)
    end
    local done_set = lower_set(cfg.done_values)

    local completed = {}
    local checked = {}
    local out = {}
    for _, t in ipairs(tasks) do
        if t.due_date ~= nil then
            out[#out + 1] = t -- inline-dated always kept
        else
            if not checked[t.file_path] then
                checked[t.file_path] = true
                local fm = M.parse_frontmatter(t.file_path)
                if fm then
                    local due = M.get_string(fm, cfg.due_key)
                    local status = M.get_string(fm, cfg.status_key):lower()
                    if due ~= "" and done_set[status] then
                        completed[t.file_path] = true -- BOTH due AND done required
                    end
                end
            end
            if not completed[t.file_path] then
                out[#out + 1] = t
            end
        end
    end
    return out
end

-- ── pipeline op 3: merge_due (parity: frontmatter.go:195-253) ─────────────────

--- For undated tasks in files with a frontmatter due (respecting inherit_due +
--- require_tags), set due_date to the noon epoch. Mutates in place; may append
--- a DateError. Inline-dated tasks are never touched (inline wins).
---@param tasks table[]
---@param fm_cfg table|nil
---@param date_fmt string   -- strftime, e.g. "%Y-%m-%d"
---@param date_errors table[]|nil
function M.merge_due(tasks, fm_cfg, date_fmt, date_errors)
    local cfg = M.resolve_cfg(fm_cfg)
    if not cfg.inherit_due then
        return
    end
    local spec = strftime.compile(date_fmt)

    for _, task in ipairs(tasks) do
        if task.due_date == nil then
            local fm = M.parse_frontmatter(task.file_path)
            if fm then
                local due = M.get_string(fm, cfg.due_key)
                if due ~= "" then
                    local allowed = true
                    if #cfg.require_tags > 0 then
                        -- ALL required tags must be in the FILE's FM tags
                        -- (independent of merge_tags / the task's merged tags).
                        local fmset = {}
                        for _, t in ipairs(fm.tags) do
                            fmset[t] = true
                        end
                        for _, rt in ipairs(cfg.require_tags) do
                            if not fmset[rt] then
                                allowed = false
                                break
                            end
                        end
                    end
                    if allowed then
                        local date_part, time_part = split_first_space(due)
                        local epoch = parse_due_date(date_part, spec, task.file_path, "frontmatter due", date_errors)
                        if epoch ~= nil then
                            task.due_date = epoch
                            if time_part ~= nil and time_part ~= "" then
                                task.due_time = trim(time_part)
                            end
                        end
                    end
                end
            end
        end
    end
end
M.merge_frontmatter_due = M.merge_due -- blueprint-03 alias

-- ── ScanProjects FM interface (parity: scan.go:185-246) ───────────────────────

--- Convenience for the project scan: the three FM fields a project candidate
--- needs. Shares the per-refresh cache. Returns nil when there is no FM.
---@param path string
---@param fm_cfg table|nil
---@return table|nil  -- { tags=string[], due=string, status=string }
function M.file_fields(path, fm_cfg)
    local cfg = M.resolve_cfg(fm_cfg)
    local fm = M.parse_frontmatter(path)
    if not fm then
        return nil
    end
    return {
        tags = fm.tags,
        due = M.get_string(fm, cfg.due_key),
        status = M.get_string(fm, cfg.status_key),
    }
end

--- Build a synthetic SortLast project Task from a file's frontmatter, or nil.
--- Skips when: not tagged "project" (hard-coded literal, independent of
--- require_tags), no due, status ∈ done_values, or the due date is invalid.
---@param path string
---@param fm_cfg table|nil
---@param date_fmt string
---@param date_errors table[]|nil
---@return table|nil
function M.project_task(path, fm_cfg, date_fmt, date_errors)
    local cfg = M.resolve_cfg(fm_cfg)
    local fm = M.parse_frontmatter(path)
    if not fm then
        return nil
    end

    local has_project = false
    for _, tag in ipairs(fm.tags) do
        if tag == "project" then
            has_project = true
            break
        end
    end
    if not has_project then
        return nil
    end

    local due = M.get_string(fm, cfg.due_key)
    if due == "" then
        return nil
    end

    local status = M.get_string(fm, cfg.status_key):lower()
    local done_set = lower_set(cfg.done_values)
    if done_set[status] then
        return nil
    end

    local spec = strftime.compile(date_fmt)
    local date_part, time_part = split_first_space(due)
    local epoch = parse_due_date(date_part, spec, path, "frontmatter project due", date_errors)
    if epoch == nil then
        return nil
    end

    local base = path:match("([^/]+)$") or path
    local body = (base:gsub("%.md$", ""))

    return {
        file_path = path,
        line_number = 1,
        body = body,
        due_date = epoch,
        due_time = (time_part ~= nil and time_part ~= "") and trim(time_part) or "",
        duration = "",
        tags = fm.tags,
        status = "open",
        markers = {},
        sort_last = true,
    }
end

return M
