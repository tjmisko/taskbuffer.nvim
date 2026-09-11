-- Drive controls from a separate editor so the target keeps its normal event loop.
local config = vim.json.decode(table.concat(vim.fn.readfile(vim.env.TASKBUFFER_DEMO_CONFIG), "\n"))
config.root, config.check = config.root .. "/controls", false
config.control = config.root .. "/control.json"
for _, name in ipairs({ "vault", "tmp", "state", "config", "data", "cache" }) do
    vim.fn.mkdir(config.root .. "/" .. name, "p")
end
local config_path = config.root .. "/demo.json"
vim.fn.writefile({ vim.json.encode(config) }, config_path)
local stderr = {}
local job = vim.fn.jobstart({
    vim.v.progpath,
    "--headless",
    "--embed",
    "-u",
    config.repo .. "/scripts/demo/init.lua",
    "-i",
    "NONE",
    "--noplugin",
}, {
    rpc = true,
    cwd = config.root .. "/vault",
    env = {
        TASKBUFFER_DEMO_CONFIG = config_path,
        XDG_CONFIG_HOME = config.root .. "/config",
        XDG_DATA_HOME = config.root .. "/data",
        XDG_CACHE_HOME = config.root .. "/cache",
        XDG_STATE_HOME = config.root .. "/state",
        NVIM_LOG_FILE = config.root .. "/nvim.log",
    },
    on_stderr = function(_, lines)
        vim.list_extend(stderr, lines)
    end,
})
assert(job > 0, "could not launch control test editor")
local function lua(code)
    return vim.rpcrequest(job, "nvim_exec_lua", code, {})
end
local function input(keys)
    vim.rpcrequest(job, "nvim_input", keys)
end
local function wait(code)
    assert(
        vim.wait(5000, function()
            return lua(code) == true
        end, 20),
        "control timed out: " .. code
    )
end
local function title(text)
    wait(
        "return package.loaded.keys ~= nil and require('keys').title:find("
            .. string.format("%q", text)
            .. ", 1, true) ~= nil"
    )
end
local function state()
    return vim.json.decode(table.concat(vim.fn.readfile(config.control), "\n"))
end
local ok, err = xpcall(function()
    title("F5 starts")
    input("<F5>")
    title("Starting in")
    local id = state().run_id
    input("<F6>")
    title("Paused")
    vim.wait(1300, function()
        return false
    end)
    title("Paused")
    assert(lua("return vim.bo.filetype == 'markdown'"), "pause allowed the sequence to advance")
    input("<F6>")
    title("Continuing")
    input("<F8>")
    title("Stopped")
    assert(state().status == "aborted")

    -- F5 discards sample edits and cancels any old scheduled continuation.
    input("GoDiscard this sample edit<Esc>")
    wait("return vim.bo.modified")
    input("<F5>")
    title("Starting in")
    assert(state().run_id ~= id)
    assert(
        lua("return not vim.bo.modified and not table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false)):find('Discard')")
    )
    input("<F8>")
    title("Stopped")

    -- Controls must also work while typing and while entering an Ex command.
    for _, mode in ipairs({ "i", ":" }) do
        input(mode .. "<F5>")
        title("Starting in")
        wait("return vim.api.nvim_get_mode().mode == 'n'")
        input(mode .. "<F6>")
        title("Paused")
        input("<F8>")
        title("Stopped")
    end
    assert(lua("return vim.v.errmsg == ''"), "controls raised an editor error")
end, debug.traceback)
pcall(vim.rpcrequest, job, "nvim_command", "qa!")
if vim.fn.jobwait({ job }, 1000)[1] == -1 then
    vim.fn.jobstop(job)
end
assert(ok, tostring(err) .. "\n" .. table.concat(stderr, "\n"))
print("Controls passed: pause/resume, abort, fresh replay, insert and command-line modes")
