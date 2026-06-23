-- End-to-end parity: list.lua output must byte-match the Go binary's `list`
-- stdout over the fixture vaults. Both run against the same tempdir copy at the
-- same moment, so the comparison is a literal string equality (see
-- tests/helpers/parity.lua for why no --now hook / relativization is needed).

local parity = require("tests.helpers.parity")

-- Parity needs the Go binary as the oracle. If it isn't built (e.g. a Go-free
-- CI before frozen golden files exist), skip rather than error.
if vim.fn.executable(parity.task_bin) ~= 1 then
    describe("list parity", function()
        pending("go/task_bin not built — run `cd go && go build -o task_bin .`")
    end)
    return
end

-- Compare go vs lua for one (vault, config, flags) case.
local function compare(vault_name, cfg, flags, runtime)
    local tmp = parity.copy_vault(vault_name)
    parity.apply_config(tmp, cfg)
    local golden = parity.go_list(tmp, flags)
    local got = parity.lua_list(tmp, runtime)
    assert.are.equal(golden, got)
end

describe("list parity (default config)", function()
    -- Single-source vaults that use the default format/frontmatter config.
    local vaults = {
        "basic-vault",
        "tagged-vault",
        "tag-edge-vault",
        "mixed-status-vault",
        "edge-syntax-vault",
        "frontmatter-vault",
        "frontmatter-edge-vault",
        "fm-due-vault",
        "path-edge-vault",
        "multi-source",
    }

    for _, v in ipairs(vaults) do
        it("matches Go for " .. v .. " (no flags)", function()
            compare(v, {}, {}, {})
        end)

        it("matches Go for " .. v .. " (--ignore-undated)", function()
            compare(v, {}, { "--ignore-undated" }, { ignore_undated = true })
        end)

        it("matches Go for " .. v .. " (--markers)", function()
            compare(v, {}, { "--markers" }, { markers = true })
        end)
    end
end)

describe("list parity (async path)", function()
    it("list_async matches Go (and the sync path) for basic-vault", function()
        local tmp = parity.copy_vault("basic-vault")
        parity.apply_config(tmp, {})
        local golden = parity.go_list(tmp, {})

        local done, got_text, got_err = false, nil, nil
        require("taskbuffer.list").list_async({}, function(text, err)
            got_text, got_err, done = text, err, true
        end)
        vim.wait(5000, function()
            return done
        end, 10)
        assert.is_true(done, "list_async did not call back")
        assert.is_nil(got_err)
        assert.are.equal(golden, got_text)
    end)
end)

describe("list parity (tag filter)", function()
    it("matches Go for tagged-vault --tag work", function()
        compare("tagged-vault", {}, { "--tag", "work" }, { tags = { "work" } })
    end)

    it("matches Go for tag-edge-vault --tag urgent --tag home (OR)", function()
        compare("tag-edge-vault", {}, { "--tag", "urgent", "--tag", "home" }, { tags = { "urgent", "home" } })
    end)
end)

describe("list parity (custom format ctx plumbing)", function()
    -- Custom multi-word checkboxes + a 2-element date wrapper {date}. Exercises
    -- the scan_pattern alternation, status_map, and the 2-elem wrapper branch.
    local custom = {
        formats = {
            checkbox = { open = "TODO ", done = "DONE ", skip = "SKIP " },
            date_wrapper = { "{", "}" },
        },
    }
    it("matches Go for custom-format-vault (custom checkbox + wrapper)", function()
        compare("custom-format-vault", custom, {}, {})
    end)
    it("matches Go for custom-format-vault (+ --markers)", function()
        compare("custom-format-vault", custom, { "--markers" }, { markers = true })
    end)
end)

describe("list parity (custom horizons ctx plumbing)", function()
    local specs = {
        { label = "# Overdue", after = "past" },
        { label = "# Now", after = 0 },
        { label = "# Next Week", after = "1w" },
        { label = "# Backlog", undated = true },
    }
    it("matches Go for horizons-vault (custom specs, default overlap)", function()
        compare("horizons-vault", { horizons = specs }, {}, {})
    end)
    it("matches Go for horizons-vault (overlap=first_match)", function()
        compare("horizons-vault", { horizons = specs, horizons_overlap = "first_match" }, {}, {})
    end)
    it("matches Go for horizons-vault (week_start=sunday)", function()
        compare("horizons-vault", { horizons = specs, week_start = "sunday" }, {}, {})
    end)
end)

describe("tags parity (default config)", function()
    local vaults = { "tagged-vault", "tag-edge-vault", "fm-due-vault", "frontmatter-vault" }
    for _, v in ipairs(vaults) do
        it("matches Go tags for " .. v, function()
            local tmp = parity.copy_vault(v)
            parity.apply_config(tmp, {})
            local golden = parity.go_tags(tmp)
            local got = require("taskbuffer.list").tags({})
            assert.are.same(golden, got)
        end)
    end
end)
