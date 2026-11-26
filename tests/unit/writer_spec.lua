local source = require("taskbuffer.source")
local writer = require("taskbuffer.writer")
local undo = require("taskbuffer.undo")
local util = require("taskbuffer.util")

describe("background writer", function()
    local dir, path, notified, original_notify, renames, original_rename

    local function read(target)
        local file = assert(io.open(target or path, "rb"))
        local bytes = file:read("*a")
        file:close()
        return bytes
    end

    local function make(name, text)
        local target = dir .. "/" .. name
        local file = assert(io.open(target, "wb"))
        file:write(text)
        file:close()
        return target
    end

    before_each(function()
        dir = vim.uv.fs_realpath(vim.fn.tempname() .. "") or vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        dir = vim.uv.fs_realpath(dir)
        path = make("note.md", "- [ ] one\n- [ ] two\n- [ ] three\n")
        undo.reset()
        notified = {}
        original_notify = vim.notify
        vim.notify = function(message, level)
            notified[#notified + 1] = { message = message, level = level }
        end
        renames = 0
        original_rename = vim.uv.fs_rename
        vim.uv.fs_rename = function(...)
            renames = renames + 1
            return original_rename(...)
        end
    end)

    after_each(function()
        writer.flush_sync()
        vim.uv.fs_rename = original_rename
        vim.notify = original_notify
        vim.fn.setfperm(dir, "rwxr-xr-x")
        vim.fn.delete(dir, "rf")
    end)

    describe("rebase", function()
        it("should apply a record at its own line when the lines are unchanged", function()
            local data, conflicts =
                writer.rebase("a\nb\nc\n", { { line = 2, old_lines = { "b" }, new_lines = { "B" } } })
            assert.are.equal("a\nB\nc\n", data)
            assert.are.same({}, conflicts)
        end)

        it("should apply a record at its unique match when lines shifted", function()
            local data, conflicts =
                writer.rebase("new\nnew2\na\nb\nc\n", { { line = 2, old_lines = { "b" }, new_lines = { "B" } } })
            assert.are.equal("new\nnew2\na\nB\nc\n", data)
            assert.are.same({}, conflicts)
        end)

        it("should conflict when the old text occurs more than once elsewhere", function()
            local data, conflicts =
                writer.rebase("b\nx\nb\n", { { line = 2, old_lines = { "b" }, new_lines = { "B" } } })
            assert.are.equal("b\nx\nb\n", data)
            assert.are.equal(1, #conflicts)
        end)

        it("should conflict when the old text is gone", function()
            local _, conflicts = writer.rebase("a\nz\n", { { line = 2, old_lines = { "b" }, new_lines = { "B" } } })
            assert.are.equal(1, #conflicts)
        end)

        it("should still apply the other records when one conflicts", function()
            local data, conflicts = writer.rebase("a\nq\nc\n", {
                { line = 1, old_lines = { "a" }, new_lines = { "A" } },
                { line = 2, old_lines = { "b" }, new_lines = { "B" } },
                { line = 3, old_lines = { "c" }, new_lines = { "C" } },
            })
            assert.are.equal("A\nq\nC\n", data)
            assert.are.equal(1, #conflicts)
            assert.are.equal("b", conflicts[1].old_lines[1])
        end)

        it("should survive records that insert or delete lines", function()
            local data, conflicts = writer.rebase("a\nb\nc\n", {
                { line = 2, old_lines = { "b" }, new_lines = { "b1", "b2" } },
                { line = 5, old_lines = { "c" }, new_lines = {} },
            })
            assert.are.equal("a\nb1\nb2\n", data)
            assert.are.same({}, conflicts)
        end)

        it("should handle empty disk content", function()
            local data, conflicts = writer.rebase("", { { line = 1, old_lines = { "x" }, new_lines = { "y" } } })
            assert.are.equal("", data)
            assert.are.equal(1, #conflicts)
        end)
    end)

    describe("staging", function()
        it("should show staged content to readers before it reaches disk", function()
            assert.is_true(source.write(path, "- [x] one\n- [ ] two\n- [ ] three\n"))
            assert.are.equal("- [x] one", util.read_line_from_file(path, 1))
            assert.are.equal("- [ ] one\n- [ ] two\n- [ ] three\n", read())
            assert.is_true(source.pending(path))
        end)

        it("should merge consecutive edits of one line into one record", function()
            util.replace_line_in_file(path, 2, "- [x] two")
            util.replace_line_in_file(path, 2, "- [x] two ::done")
            local edits = source.overlay[path].edits
            assert.are.equal(1, #edits)
            assert.are.same({ "- [ ] two" }, edits[1].old_lines)
            assert.are.same({ "- [x] two ::done" }, edits[1].new_lines)
        end)

        it("should keep a record per line when different lines change", function()
            util.replace_line_in_file(path, 1, "- [x] one")
            util.replace_line_in_file(path, 3, "- [x] three")
            assert.are.equal(2, #source.overlay[path].edits)
        end)

        it("should do nothing when the content is unchanged", function()
            assert.is_true(source.write(path, read()))
            assert.is_false(source.pending(path))
        end)

        it("should refuse a hard-linked source immediately", function()
            local link = dir .. "/hard.md"
            assert(vim.uv.fs_link(path, link))
            local ok, err = source.write(path, "changed\n")
            assert.is_false(ok)
            assert.is_truthy(err:find("hard links", 1, true))
            assert.is_false(source.pending(path))
        end)
    end)

    describe("writing", function()
        it("should write the staged content when the disk is unchanged", function()
            util.replace_line_in_file(path, 2, "- [x] two")
            assert.is_true(writer.flush_sync())
            assert.are.equal("- [ ] one\n- [x] two\n- [ ] three\n", read())
            assert.is_false(source.pending(path))
            assert.are.same({}, notified)
        end)

        it("should write on its own once the event loop runs", function()
            util.replace_line_in_file(path, 2, "- [x] two")
            assert.is_true(vim.wait(3000, function()
                return writer.idle()
            end, 5))
            assert.are.equal("- [ ] one\n- [x] two\n- [ ] three\n", read())
        end)

        it("should rebase onto lines that shifted on disk", function()
            util.replace_line_in_file(path, 2, "- [x] two")
            vim.fn.writefile({ "inserted", "- [ ] one", "- [ ] two", "- [ ] three" }, path)
            assert.is_true(writer.flush_sync())
            assert.are.equal("inserted\n- [ ] one\n- [x] two\n- [ ] three\n", read())
            assert.are.same({}, notified)
        end)

        it("should keep external edits of other lines", function()
            util.replace_line_in_file(path, 2, "- [x] two")
            vim.fn.writefile({ "- [ ] one", "- [ ] two", "- [ ] 3 externally" }, path)
            writer.flush_sync()
            assert.are.equal("- [ ] one\n- [x] two\n- [ ] 3 externally\n", read())
        end)

        it("should revert, drop the undo entry, and warn once when the line changed on disk", function()
            local old_line, new_line = "- [ ] two", "- [x] two"
            util.replace_line_in_file(path, 2, new_line)
            undo.push({
                op = "check",
                edits = { { filepath = path, linenumber = 2, old_line = old_line, new_line = new_line } },
                timestamp = os.time(),
            })
            vim.fn.writefile({ "- [ ] one", "- [ ] two edited elsewhere", "- [ ] three" }, path)
            writer.flush_sync()
            assert.are.equal("- [ ] one\n- [ ] two edited elsewhere\n- [ ] three\n", read())
            assert.are.equal(1, #notified)
            assert.are.equal(vim.log.levels.WARN, notified[1].level)
            assert.is_truthy(notified[1].message:find("note.md", 1, true))
            assert.is_truthy(notified[1].message:find("two", 1, true))
            assert.are.equal(0, (undo.depth()))
            assert.are.equal("- [ ] two edited elsewhere", util.read_line_from_file(path, 2))
        end)

        it("should drop every undo entry of a merged record when the line changed on disk", function()
            local l0, l1, l2 = "- [ ] two", "- [x] two", "- [x] two ::done"
            util.replace_line_in_file(path, 2, l1)
            undo.push({
                op = "check",
                edits = { { filepath = path, linenumber = 2, old_line = l0, new_line = l1 } },
                timestamp = os.time(),
            })
            util.replace_line_in_file(path, 2, l2)
            undo.push({
                op = "check",
                edits = { { filepath = path, linenumber = 2, old_line = l1, new_line = l2 } },
                timestamp = os.time(),
            })
            assert.are.equal(2, (undo.depth()))
            vim.fn.writefile({ "- [ ] one", "- [ ] two edited elsewhere", "- [ ] three" }, path)
            writer.flush_sync()
            assert.are.equal(0, (undo.depth()))
        end)

        it("should conflict when the matching text became ambiguous", function()
            util.replace_line_in_file(path, 2, "- [x] two")
            vim.fn.writefile({ "- [ ] two", "- [ ] one", "- [ ] two", "- [ ] three" }, path)
            writer.flush_sync()
            assert.are.equal("- [ ] two\n- [ ] one\n- [ ] two\n- [ ] three\n", read())
            assert.are.equal(1, #notified)
        end)

        it("should apply the other records of a batch when one conflicts", function()
            util.replace_line_in_file(path, 1, "- [x] one")
            util.replace_line_in_file(path, 3, "- [x] three")
            vim.fn.writefile({ "- [ ] one", "- [ ] two", "- [ ] 3 changed" }, path)
            writer.flush_sync()
            assert.are.equal("- [x] one\n- [ ] two\n- [ ] 3 changed\n", read())
            assert.are.equal(1, #notified)
        end)

        it("should not touch the file when an undo lands before the write", function()
            local before = vim.uv.fs_stat(path)
            local old_line, new_line = "- [ ] two", "- [x] two"
            util.replace_line_in_file(path, 2, new_line)
            undo.push({
                op = "check",
                edits = { { filepath = path, linenumber = 2, old_line = old_line, new_line = new_line } },
                timestamp = os.time(),
            })
            undo.undo()
            assert.are.equal(old_line, util.read_line_from_file(path, 2))
            assert.is_true(writer.flush_sync())
            assert.are.equal("- [ ] one\n- [ ] two\n- [ ] three\n", read())
            assert.are.equal(0, renames)
            assert.are.equal(before.ino, vim.uv.fs_stat(path).ino)
            for _, note in ipairs(notified) do
                assert.is_true(note.level < vim.log.levels.WARN, note.message)
            end
        end)

        it("should coalesce edits that arrive during an in-flight write", function()
            local delayed = vim.uv.fs_rename
            vim.uv.fs_rename = function(from, to, callback)
                renames = renames + 1
                vim.defer_fn(function()
                    original_rename(from, to, callback)
                end, 60)
            end
            util.replace_line_in_file(path, 1, "- [x] one")
            assert.is_true(vim.wait(3000, function()
                return source.overlay[path] and source.overlay[path].inflight ~= nil
            end, 1))
            util.replace_line_in_file(path, 2, "- [x] two")
            util.replace_line_in_file(path, 3, "- [x] three")
            assert.is_true(writer.flush_sync())
            vim.uv.fs_rename = delayed
            assert.are.equal("- [x] one\n- [x] two\n- [x] three\n", read())
            assert.are.equal(2, renames)
            assert.are.same({}, notified)
        end)

        it("should drain several files at once", function()
            local paths = {}
            for index = 1, 6 do
                paths[index] = make("n" .. index .. ".md", "- [ ] task " .. index .. "\n")
                util.replace_line_in_file(paths[index], 1, "- [x] task " .. index)
            end
            assert.is_true(writer.flush_sync())
            for index, target in ipairs(paths) do
                assert.are.equal("- [x] task " .. index .. "\n", read(target))
            end
            assert.is_true(writer.idle())
        end)

        it("should leave no temporary files behind", function()
            util.replace_line_in_file(path, 1, "- [x] one")
            writer.flush_sync()
            assert.are.same({ "note.md" }, vim.fn.readdir(dir))
        end)

        it("should keep mode bits when rewriting a 0600 note", function()
            assert(vim.uv.fs_chmod(path, 384))
            util.replace_line_in_file(path, 1, "- [x] one")
            writer.flush_sync()
            assert.are.equal(384, vim.uv.fs_stat(path).mode % 512)
        end)

        it("should rewrite the symlink target and leave the link in place", function()
            local link = dir .. "/link.md"
            assert(vim.uv.fs_symlink(path, link))
            util.replace_line_in_file(link, 1, "- [x] one")
            writer.flush_sync()
            assert.are.equal("link", vim.uv.fs_lstat(link).type)
            assert.are.equal("- [x] one\n- [ ] two\n- [ ] three\n", read())
        end)

        it("should not spawn any process while writing", function()
            local saved = { vim.system, vim.fn.system, vim.fn.jobstart, vim.uv.spawn }
            local calls = 0
            local function count()
                calls = calls + 1
                error("process spawned during write")
            end
            vim.system, vim.fn.system, vim.fn.jobstart, vim.uv.spawn = count, count, count, count
            local ok = pcall(function()
                util.replace_line_in_file(path, 1, "- [x] one")
                writer.flush_sync()
            end)
            vim.system, vim.fn.system, vim.fn.jobstart, vim.uv.spawn = unpack(saved)
            assert.is_true(ok)
            assert.are.equal(0, calls)
            assert.are.equal("- [x] one\n- [ ] two\n- [ ] three\n", read())
        end)

        it("should preserve CRLF and a missing final newline", function()
            path = make("crlf.md", "title\r\n- [ ] task")
            util.replace_line_in_file(path, 2, "- [x] task")
            writer.flush_sync()
            assert.are.equal("title\r\n- [x] task", read())
        end)
    end)

    describe("failures", function()
        local function skip_if_writable_directory(target)
            local probe = io.open(target .. "/probe", "w")
            if probe then
                probe:close()
                os.remove(target .. "/probe")
                return true
            end
            return false
        end

        it("should revert in memory, drop the undo entry, and warn once when the write fails", function()
            local old_line, new_line = "- [ ] one", "- [x] one"
            util.replace_line_in_file(path, 1, new_line)
            util.replace_line_in_file(path, 3, "- [x] three")
            undo.push({
                op = "check",
                edits = { { filepath = path, linenumber = 1, old_line = old_line, new_line = new_line } },
                timestamp = os.time(),
            })
            vim.fn.setfperm(dir, "r-xr-xr-x")
            if skip_if_writable_directory(dir) then
                return pending("running with permission to write read-only directories")
            end
            writer.flush_sync()
            vim.fn.setfperm(dir, "rwxr-xr-x")
            assert.are.equal("- [ ] one\n- [ ] two\n- [ ] three\n", read())
            assert.are.equal("- [ ] one", util.read_line_from_file(path, 1))
            assert.is_false(source.pending(path))
            assert.are.equal(1, #notified)
            assert.are.equal(0, (undo.depth()))
        end)

        it("should still write the other files when one fails", function()
            local other_dir = dir .. "/other"
            vim.fn.mkdir(other_dir, "p")
            local ro = make("other/ro.md", "- [ ] ro\n")
            local ok_path = make("fine.md", "- [ ] fine\n")
            util.replace_line_in_file(ro, 1, "- [x] ro")
            util.replace_line_in_file(ok_path, 1, "- [x] fine")
            vim.fn.setfperm(other_dir, "r-xr-xr-x")
            if skip_if_writable_directory(other_dir) then
                vim.fn.setfperm(other_dir, "rwxr-xr-x")
                return pending("running with permission to write read-only directories")
            end
            writer.flush_sync()
            vim.fn.setfperm(other_dir, "rwxr-xr-x")
            assert.are.equal("- [x] fine\n", read(ok_path))
            assert.are.equal("- [ ] ro\n", read(ro))
            assert.are.equal(1, #notified)
        end)

        it("should report a source file that vanished", function()
            util.replace_line_in_file(path, 1, "- [x] one")
            os.remove(path)
            writer.flush_sync()
            assert.are.equal(1, #notified)
            assert.is_false(source.pending(path))
        end)
    end)
end)
