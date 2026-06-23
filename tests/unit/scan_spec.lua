-- Ported from go/scan_test.go, go/scan_multi_test.go, and the path/glob subset
-- of go/integration_test.go. These exercise real rg (and the grep fallback)
-- behavior, so the assertions are on the RawMatch[] contract (path/line/text)
-- rather than parsed Task fields.
--
-- IMPORTANT: fixtures are created under vim.fn.tempname() (an OS tempdir OUTSIDE
-- this worktree). The worktree lives under .worktrees/, which the parent repo
-- gitignores, and rg respects gitignore -> scanning a worktree path returns
-- ZERO matches. tempname() dirs have no .git/.gitignore ancestor, so rg behaves
-- normally there. This mirrors how the Go tests use t.TempDir().

local scan = require("taskbuffer.scan")
local uv = vim.uv or vim.loop

-- --- fixture helpers --------------------------------------------------------

local function make_vault()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

local function write_file(dir, rel, content)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local fd = assert(io.open(path, "w"))
    fd:write(content)
    fd:close()
    return path
end

local function ctx(...)
    return { sources = { ... } }
end

-- Find a match whose text contains the substring.
local function find_text(matches, substr)
    for _, m in ipairs(matches) do
        if m.text:find(substr, 1, true) then
            return m
        end
    end
    return nil
end

-- Stable key for comparing two RawMatch lists across tools (rg vs grep order differs).
local function normalize(matches)
    local copy = {}
    for i, m in ipairs(matches) do
        copy[i] = m
    end
    table.sort(copy, function(a, b)
        if a.path ~= b.path then
            return a.path < b.path
        end
        return a.line_number < b.line_number
    end)
    return copy
end

-- ===========================================================================
-- scan_test.go
-- ===========================================================================

describe("scan.scan — basic temp dir", function()
    -- TestScan_FindsTasksInTempDir
    it("finds all task lines across files, absolute paths, line>=1, nonempty text", function()
        local dir = make_vault()
        write_file(
            dir,
            "project.md",
            "# Project\n"
                .. "- [ ] First task (@[[2026-02-17]])\n"
                .. "- [x] Done task (@[[2026-02-16]] 10:00)::complete [[2026-02-16]] 11:00\n"
                .. "Some other content\n"
        )
        write_file(dir, "empty.md", "# Nothing here\n")
        write_file(dir, "daily.md", "\t- [ ] Indented task <30m> (@[[2026-02-18]])\n")
        write_file(dir, "someday.md", "- [ ] Investigate OOM Kill Root Cause\n" .. "- [x] Already done undated task\n")

        local matches, err = scan.scan(ctx(dir))
        assert.is_nil(err)
        assert.are.equal(5, #matches)
        for _, m in ipairs(matches) do
            assert.is_truthy(m.path:sub(1, 1) == "/", "path is absolute: " .. m.path)
            assert.is_true(m.line_number >= 1)
            assert.is_truthy(m.text ~= "")
        end
    end)

    -- TestScan_EmptyDir / TestPath_EmptyDirectory
    it("returns no matches and no error for an empty directory", function()
        local dir = make_vault()
        local matches, err = scan.scan(ctx(dir))
        assert.is_nil(err)
        assert.are.equal(0, #matches)
    end)

    -- TestScan_NoMatchesInFile / TestPath_NoTasksInMarkdown
    it("returns no matches and no error for a markdown file with no tasks", function()
        local dir = make_vault()
        write_file(dir, "notes.md", "No tasks here\n")
        local matches, err = scan.scan(ctx(dir))
        assert.is_nil(err)
        assert.are.equal(0, #matches)
    end)
end)

-- ===========================================================================
-- scan_multi_test.go
-- ===========================================================================

describe("scan.scan — multiple sources", function()
    -- TestScan_MultipleDirs
    it("unions matches from two directories and preserves text", function()
        local dir1 = make_vault()
        local dir2 = make_vault()
        write_file(dir1, "a.md", "- [ ] Task in dir1 (@[[2026-02-17]])\n")
        write_file(dir2, "b.md", "- [ ] Task in dir2 (@[[2026-02-18]])\n")

        local matches, err = scan.scan(ctx(dir1, dir2))
        assert.is_nil(err)
        assert.are.equal(2, #matches)
        assert.is_truthy(find_text(matches, "Task in dir1"))
        assert.is_truthy(find_text(matches, "Task in dir2"))
    end)
end)

describe("scan.deduplicate_paths", function()
    -- TestDeduplicatePaths_Nested
    it("drops a nested path in favor of its parent", function()
        local dir = make_vault()
        local sub = dir .. "/sub"
        vim.fn.mkdir(sub, "p")
        local got = scan.deduplicate_paths({ dir, sub })
        assert.are.equal(1, #got)
        assert.are.equal(uv.fs_realpath(dir), got[1])
    end)

    -- TestDeduplicatePaths_Disjoint
    it("keeps two disjoint paths", function()
        local dir1 = make_vault()
        local dir2 = make_vault()
        local got = scan.deduplicate_paths({ dir1, dir2 })
        assert.are.equal(2, #got)
    end)

    it("collapses exact duplicates to one", function()
        local dir = make_vault()
        local got = scan.deduplicate_paths({ dir, dir })
        assert.are.equal(1, #got)
    end)

    it("keeps a nonexistent path as-is (realpath fails -> original)", function()
        local got = scan.deduplicate_paths({ "/nonexistent/path/xyz" })
        assert.are.equal(1, #got)
        assert.are.equal("/nonexistent/path/xyz", got[1])
    end)
end)

describe("scan.expand_globs", function()
    -- TestScan_GlobExpansion (glob matches a directory)
    it("expands a `*` glob to matching entries", function()
        local dir = make_vault()
        vim.fn.mkdir(dir .. "/notes", "p")
        local got = scan.expand_globs({ dir .. "/note*" })
        assert.are.equal(1, #got)
        assert.are.equal(uv.fs_realpath(dir .. "/notes"), got[1])
    end)

    it("passes a plain (non-glob) path through verbatim", function()
        local dir = make_vault()
        local got = scan.expand_globs({ dir })
        assert.are.equal(1, #got)
        assert.are.equal(uv.fs_realpath(dir), got[1])
    end)

    it("a no-match glob yields nothing", function()
        local dir = make_vault()
        local got = scan.expand_globs({ dir .. "/nonexist-*" })
        assert.are.equal(0, #got)
    end)
end)

-- ===========================================================================
-- integration_test.go — path edge cases
-- ===========================================================================

describe("scan.scan — path edge cases", function()
    -- TestPath_SpacesInPath
    it("scans a directory with spaces in its name (argv array, no quoting)", function()
        local dir = make_vault()
        write_file(dir, "space dir/note.md", "- [ ] Task in space dir (@[[2026-02-17]])\n")
        local matches, err = scan.scan(ctx(dir .. "/space dir"))
        assert.is_nil(err)
        assert.are.equal(1, #matches)
        assert.is_truthy(find_text(matches, "Task in space dir"))
    end)

    -- TestPath_DeeplyNested
    it("finds deeply nested tasks via recursive walk", function()
        local dir = make_vault()
        write_file(dir, "a/b/c/d/deep.md", "- [ ] Deeply nested task\n")
        local matches, err = scan.scan(ctx(dir))
        assert.is_nil(err)
        assert.is_truthy(find_text(matches, "Deeply nested task"))
    end)

    -- TestPath_NonExistentPath
    it("returns an error for a nonexistent path (rg exit 2 with stderr)", function()
        local matches, err = scan.scan(ctx("/nonexistent/path/that/does/not/exist"))
        assert.is_not_nil(err)
        assert.is_nil(matches)
    end)

    -- TestPath_SymlinkDedup
    it("dedups a real dir and a symlink to it down to one scan", function()
        local dir = make_vault()
        local real = dir .. "/symlink-target"
        vim.fn.mkdir(real, "p")
        write_file(dir, "symlink-target/t.md", "- [ ] Symlinked task\n")
        local link = dir .. "/linked"
        assert(uv.fs_symlink(real, link))

        local matches, err = scan.scan(ctx(real, link))
        assert.is_nil(err)
        assert.are.equal(1, #matches)
    end)

    -- TestPath_OverlappingNested
    it("dedups overlapping parent+nested sources to the parent", function()
        local dir = make_vault()
        write_file(dir, "deeply/nested/dir/note.md", "- [ ] Overlap task\n")
        local matches, err = scan.scan(ctx(dir .. "/deeply", dir .. "/deeply/nested/dir"))
        assert.is_nil(err)
        assert.are.equal(1, #matches)
    end)

    -- TestPath_ExactDuplicates
    it("dedups an exactly duplicated source but still returns all its tasks", function()
        local dir = make_vault()
        write_file(dir, "normal/n.md", "- [ ] Dup task one\n- [ ] Dup task two\n")
        local matches, err = scan.scan(ctx(dir .. "/normal", dir .. "/normal"))
        assert.is_nil(err)
        assert.are.equal(2, #matches)
    end)

    -- TestPath_ParentScansAll (>= 5; rg does not follow the `linked` symlink)
    it("scanning the parent finds at least 5 tasks and does not follow symlinks", function()
        local dir = make_vault()
        write_file(dir, "normal/a.md", "- [ ] Normal one\n- [ ] Normal two\n")
        write_file(dir, "space dir/b.md", "- [ ] Spaced\n")
        write_file(dir, "deeply/nested/dir/c.md", "- [ ] Nested\n")
        write_file(dir, "symlink-target/d.md", "- [ ] Target\n")
        assert(uv.fs_symlink(dir .. "/symlink-target", dir .. "/linked"))

        local matches, err = scan.scan(ctx(dir))
        assert.is_nil(err)
        assert.is_true(#matches >= 5, "got " .. #matches .. " matches, want >= 5")
    end)
end)

-- ===========================================================================
-- integration_test.go — glob vault
-- ===========================================================================

describe("scan.scan — globs", function()
    local function glob_vault()
        local dir = make_vault()
        write_file(dir, "notes-1/a.md", "- [ ] Glob one\n")
        write_file(dir, "notes-2/b.md", "- [ ] Glob two\n")
        write_file(dir, "notes-3/c.md", "- [ ] Glob three\n")
        write_file(dir, "extra.md", "- [ ] Glob extra\n")
        return dir
    end

    -- TestGlob_StarWildcard
    it("notes-* matches the three notes dirs", function()
        local dir = glob_vault()
        local matches, err = scan.scan(ctx(dir .. "/notes-*"))
        assert.is_nil(err)
        assert.are.equal(3, #matches)
    end)

    -- TestGlob_QuestionMark
    it("notes-? matches the three single-char-suffixed dirs", function()
        local dir = glob_vault()
        local matches, err = scan.scan(ctx(dir .. "/notes-?"))
        assert.is_nil(err)
        assert.are.equal(3, #matches)
    end)

    -- TestGlob_MatchAll
    it("* matches every entry in the vault", function()
        local dir = glob_vault()
        local matches, err = scan.scan(ctx(dir .. "/*"))
        assert.is_nil(err)
        assert.are.equal(4, #matches)
    end)

    -- TestGlob_NoMatch
    it("a no-match glob yields no matches and no rg invocation", function()
        local dir = glob_vault()
        local matches, err = scan.scan(ctx(dir .. "/nonexist-*"))
        assert.is_nil(err)
        assert.are.equal(0, #matches)
    end)
end)

-- ===========================================================================
-- Content robustness — the NUL-split parser (no Go analogue; protects D2/D4)
-- ===========================================================================

describe("scan.scan — content robustness", function()
    it("preserves arbitrary colons and unicode in the matched text", function()
        local dir = make_vault()
        local body = "- [ ] body: with: colons cafe\xc3\xa9 12:30"
        write_file(dir, "weird.md", body .. "\n")
        local matches, err = scan.scan(ctx(dir))
        assert.is_nil(err)
        assert.are.equal(1, #matches)
        assert.are.equal(body, matches[1].text)
    end)

    it("matches indented tasks (leading tab/spaces)", function()
        local dir = make_vault()
        write_file(dir, "ind.md", "\t- [ ] Tabbed\n    - [ ] Spaced\n")
        local matches, err = scan.scan(ctx(dir))
        assert.is_nil(err)
        assert.are.equal(2, #matches)
    end)
end)

-- ===========================================================================
-- grep fallback equivalence (the only coverage for the grep path)
-- ===========================================================================

describe("scan.scan — rg vs grep equivalence", function()
    it("produces identical RawMatch lists with rg and with the grep fallback", function()
        if vim.fn.executable("grep") ~= 1 then
            pending("grep not available")
            return
        end
        local dir = make_vault()
        write_file(dir, "a.md", "- [ ] alpha: with colon\n- [x] beta\nplain line\n")
        write_file(dir, "sub/b.md", "\t- [ ] gamma\n")

        local rg_matches = scan.scan(ctx(dir))

        local saved = scan._have_rg
        scan._have_rg = function()
            return false
        end
        local grep_matches = scan.scan(ctx(dir))
        scan._have_rg = saved

        assert.are.same(normalize(rg_matches), normalize(grep_matches))
        assert.are.equal(3, #rg_matches)
    end)
end)

-- ===========================================================================
-- Async scan
-- ===========================================================================

describe("scan.scan_async", function()
    it("delivers matches via the callback", function()
        local dir = make_vault()
        write_file(dir, "a.md", "- [ ] async task\n- [x] async done\n")

        local done, result, cb_err
        scan.scan_async(ctx(dir), function(matches, err)
            result, cb_err, done = matches, err, true
        end)
        vim.wait(5000, function()
            return done
        end)

        assert.is_true(done)
        assert.is_nil(cb_err)
        assert.are.equal(2, #result)
    end)

    it("delivers empty result for empty sources without invoking rg", function()
        local done, result
        scan.scan_async(ctx(), function(matches)
            result, done = matches, true
        end)
        vim.wait(2000, function()
            return done
        end)
        assert.is_true(done)
        assert.are.equal(0, #result)
    end)
end)

-- ===========================================================================
-- scan_project_paths (rg -l candidate scan; paths only)
-- ===========================================================================

describe("scan.scan_project_paths", function()
    it("returns md files whose content contains a `- project` line", function()
        local dir = make_vault()
        write_file(dir, "proj.md", "---\ntags:\n  - project\ndue: 2026-07-01\n---\n# Proj\n")
        write_file(dir, "other.md", "- [ ] not a project\n")

        local files, err = scan.scan_project_paths(ctx(dir))
        assert.is_nil(err)
        assert.are.equal(1, #files)
        assert.is_truthy(files[1]:find("proj.md", 1, true))
    end)

    it("returns empty (no error) when nothing matches", function()
        local dir = make_vault()
        write_file(dir, "x.md", "- [ ] plain task\n")
        local files, err = scan.scan_project_paths(ctx(dir))
        assert.is_nil(err)
        assert.are.equal(0, #files)
    end)

    it("errors on a nonexistent path (no exit-2 special case, unlike scan)", function()
        local files, err = scan.scan_project_paths(ctx("/nonexistent/path/xyz"))
        assert.is_not_nil(err)
        assert.is_nil(files)
    end)
end)

-- ===========================================================================
-- build_pattern (overview D1)
-- ===========================================================================

describe("scan.build_pattern", function()
    it("returns the default pattern for nil/empty checkbox config", function()
        assert.are.equal(scan.DEFAULT_PATTERN, scan.build_pattern(nil))
        assert.are.equal(scan.DEFAULT_PATTERN, scan.build_pattern({}))
    end)

    it("escapes regex metachars and sorts the alternation longest-first", function()
        local p = scan.build_pattern({ open = "- [ ]", cancelled = "- [-]", done = "- [x]" })
        -- Equal-length literals; ties break alphabetically: space < '-' < 'x'.
        assert.are.equal("- \\[ \\]|- \\[-\\]|- \\[x\\]", p)
    end)

    it("dedups identical escaped literals", function()
        local p = scan.build_pattern({ a = "- [x]", b = "- [x]" })
        assert.are.equal("- \\[x\\]", p)
    end)

    it("skips whitespace-only entries", function()
        local p = scan.build_pattern({ a = "   ", b = "- [x]" })
        assert.are.equal("- \\[x\\]", p)
    end)
end)
