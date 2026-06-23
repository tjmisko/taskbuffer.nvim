-- Mutation parity: actions.<verb> must produce the same file bytes as the Go
-- binary's verb subcommand. The only volatile part of a mutation is the marker's
-- [[DATE]] HH:MM, so we run the Go verb first, extract the exact epoch it used
-- from the mutated file, then run the Lua verb on a fresh copy with that epoch —
-- making the comparison byte-exact and deterministic.

local parity = require("tests.helpers.parity")

if vim.fn.executable(parity.task_bin) ~= 1 then
    describe("mutate parity", function()
        pending("go/task_bin not built")
    end)
    return
end

local context = require("taskbuffer.context")
local actions = require("taskbuffer.actions")
local config = require("taskbuffer.config")

local function read_bytes(path)
    local fh = assert(io.open(path, "r"))
    local data = fh:read("*a")
    fh:close()
    return data
end

local function fresh_ctx()
    config.apply({}) -- default formats/frontmatter; sources irrelevant to verbs
    return context.build_context(config.values, {})
end

-- Run the Go verb on one copy, capture its bytes + the epoch it stamped; run the
-- Lua verb on a fresh copy with that epoch; assert byte equality.
local function compare(vault, rel, line, go_name, lua_fn)
    local ctx = fresh_ctx()
    local f_go = parity.copy_file(vault, rel)
    local go_bytes = parity.go_verb(f_go, line, go_name)
    local epoch = parity.marker_epoch_from_file(f_go, line) or os.time()

    local f_lua = parity.copy_file(vault, rel)
    local ok, err = lua_fn(f_lua, line, ctx, epoch)
    assert(ok, "lua verb failed: " .. tostring(err))
    assert.are.equal(go_bytes, read_bytes(f_lua))
end

describe("mutate parity (basic-vault/daily.md:3)", function()
    local V, F, L = "basic-vault", "daily.md", 3

    it("complete-at matches Go", function()
        compare(V, F, L, "complete-at", function(f, l, c, e)
            return actions.complete_at(f, l, c, e)
        end)
    end)

    it("defer matches Go (appends ::original + ::deferral)", function()
        compare(V, F, L, "defer", function(f, l, c, e)
            return actions.defer(f, l, c, e)
        end)
    end)

    it("irrelevant matches Go (checkbox then marker)", function()
        compare(V, F, L, "irrelevant", function(f, l, c, e)
            return actions.irrelevant(f, l, c, e)
        end)
    end)

    it("check matches Go (no marker)", function()
        compare(V, F, L, "check", function(f, l, c)
            return actions.check(f, l, c)
        end)
    end)
end)

describe("mutate parity (irrelevant -> unset round-trip)", function()
    -- unset removes the irrelevant marker and restores the checkbox; the final
    -- bytes are epoch-independent, so go-then-go vs lua-then-lua must match.
    it("matches Go for daily.md:3", function()
        local ctx = fresh_ctx()

        local f_go = parity.copy_file("basic-vault", "daily.md")
        parity.go_verb(f_go, 3, "irrelevant")
        local go_bytes = parity.go_verb(f_go, 3, "unset")

        local f_lua = parity.copy_file("basic-vault", "daily.md")
        assert(actions.irrelevant(f_lua, 3, ctx, os.time()))
        assert(actions.unset(f_lua, 3, ctx))
        assert.are.equal(go_bytes, read_bytes(f_lua))
    end)
end)
