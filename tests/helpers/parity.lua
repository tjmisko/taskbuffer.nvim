-- Parity harness: run the SAME fixture vault through both the Go binary and the
-- Lua pipeline and compare their stdout byte-for-byte.
--
-- Why this works without a --now hook or path relativization: both the binary
-- and list.lua scan the SAME tempdir copy at the SAME wall-clock moment, so the
-- absolute paths and the horizon bucketing (the only now-dependent output) are
-- identical. Frozen golden files (committed, Go-free CI) are a later step that
-- WILL need both — see docs/rewrite/ENV-NOTES.md §2.

local M = {}

-- Plugin/worktree root (this file is tests/helpers/parity.lua).
local function root()
    local here = debug.getinfo(1, "S").source:sub(2)
    return vim.fn.fnamemodify(here, ":h:h:h")
end

M.task_bin = root() .. "/go/task_bin"
M.fixtures = root() .. "/tests/fixtures/vaults"

--- Copy a fixture vault to a fresh OS tempdir (outside the worktree, so rg's
--- gitignore handling matches a real vault). Returns the tempdir path.
---@param name string  -- vault dir name under tests/fixtures/vaults
---@return string tmp
function M.copy_vault(name)
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local src = M.fixtures .. "/" .. name
    -- cp -a preserves symlinks + empty dirs (path-edge-vault needs both).
    local res = vim.system({ "cp", "-a", src .. "/.", tmp .. "/" }, { text = true }):wait()
    assert(res.code == 0, "cp vault failed: " .. (res.stderr or ""))
    return tmp
end

--- Apply config for a parity run. `formats`/`frontmatter`/`horizons`/... come
--- from the caller; sources is forced to {vault}. Returns the config.values in
--- effect (so the same --config JSON can be handed to the binary).
---@param vault string
---@param opts table|nil  -- extra config.setup keys (formats, frontmatter, horizons, ...)
function M.apply_config(vault, opts)
    local config = require("taskbuffer.config")
    opts = vim.deepcopy(opts or {})
    opts.sources = { vault }
    config.apply(opts)
    return config.values
end

--- Run the Go binary `list` over `vault` with the current global config.
---@param vault string
---@param flags string[]|nil  -- e.g. {"--markers"}, {"--ignore-undated"}, {"--tag","work"}
---@return string stdout
function M.go_list(vault, flags)
    local config = require("taskbuffer.config")
    local argv = { M.task_bin, "--source", vault, "--config", config.config_json_arg(), "list" }
    for _, f in ipairs(flags or {}) do
        argv[#argv + 1] = f
    end
    local res = vim.system(argv, { text = true }):wait()
    assert(res.code == 0, "go list failed (" .. tostring(res.code) .. "): " .. (res.stderr or ""))
    return res.stdout or ""
end

--- Run the Lua pipeline `list` over `vault` (global config already applied).
---@param vault string
---@param runtime table|nil  -- { markers, ignore_undated, tags }
---@return string text
function M.lua_list(vault, runtime)
    local text, err = require("taskbuffer.list").list(runtime or {})
    assert(not err, "lua list error: " .. tostring(err))
    return text or ""
end

--- Run the Go binary `tags` over `vault`.
---@return string[] tags
function M.go_tags(vault)
    local config = require("taskbuffer.config")
    local argv = { M.task_bin, "--source", vault, "--config", config.config_json_arg(), "tags" }
    local res = vim.system(argv, { text = true }):wait()
    assert(res.code == 0, "go tags failed: " .. (res.stderr or ""))
    local out = {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

-- Clear the per-file frontmatter cache (list.lua also does this every run).
function M.reset()
    require("taskbuffer.frontmatter").reset()
end

return M
