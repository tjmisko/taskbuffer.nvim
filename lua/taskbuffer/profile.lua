-- Opt-in wall-clock timings. No timers, clock reads, or sample allocations
-- while disabled. Samples contain stage names and durations only.
local M = {}
local uv = vim.uv or vim.loop
local enabled = false
local generation = 0
local stages = {}
local timer
local last_tick
local interval_ms = 20
local sample_limit = 256

local function record(name, ms)
    local stat = stages[name]
    if not stat then
        stat = { count = 0, total_ms = 0, max_ms = 0, samples = {} }
        stages[name] = stat
    end
    stat.count = stat.count + 1
    stat.total_ms = stat.total_ms + ms
    stat.max_ms = math.max(stat.max_ms, ms)
    stat.samples[(stat.count - 1) % sample_limit + 1] = ms
end

function M.begin(name)
    if enabled then
        return { name = name, started = uv.hrtime(), generation = generation }
    end
end

function M.finish(span)
    if span and enabled and span.generation == generation and not span.finished then
        span.finished = true
        record(span.name, (uv.hrtime() - span.started) / 1e6)
    end
end

local function pack(...)
    local result = { ... }
    result.n = select("#", ...)
    return result
end

-- Preserve all returns (including nils) and record failed calls before rethrowing.
function M.measure(name, fn, ...)
    if not enabled then
        return fn(...)
    end
    local span = M.begin(name)
    local result = pack(pcall(fn, ...))
    M.finish(span)
    if not result[1] then
        error(result[2], 0)
    end
    return unpack(result, 2, result.n)
end

function M.wrap(name, fn)
    return function(...)
        return M.measure(name, fn, ...)
    end
end

local function sample_delay()
    local now = uv.hrtime()
    record("event_loop.delay", math.max(0, (now - last_tick) / 1e6 - interval_ms))
    last_tick = now
end

function M.stop()
    if timer then
        -- Include a stall that ends immediately before :TasksProfile stop.
        if (uv.hrtime() - last_tick) / 1e6 >= interval_ms then
            sample_delay()
        end
        timer:stop()
        timer:close()
        timer = nil
    end
    enabled = false
    generation = generation + 1 -- discard callbacks from an older session
end

function M.start()
    M.stop()
    stages = {}
    enabled = true
    local session = generation
    local pending = false
    last_tick = uv.hrtime()
    timer = assert(uv.new_timer())
    timer:start(interval_ms, interval_ms, function()
        if pending then
            return -- never accumulate scheduled callbacks during a stall
        end
        pending = true
        vim.schedule(function()
            if enabled and session == generation then
                sample_delay()
            end
            pending = false
        end)
    end)
end

function M.reset()
    if enabled then
        M.start()
    else
        stages = {}
        generation = generation + 1
    end
end

function M.snapshot()
    local rows = {}
    for name, stat in pairs(stages) do
        local samples = vim.list_slice(stat.samples)
        table.sort(samples)
        rows[#rows + 1] = {
            name = name,
            count = stat.count,
            total_ms = stat.total_ms,
            mean_ms = stat.total_ms / stat.count,
            max_ms = stat.max_ms,
            p95_ms = samples[math.ceil(#samples * 0.95)],
            sample_count = #samples,
        }
    end
    table.sort(rows, function(a, b)
        if a.total_ms == b.total_ms then
            return a.name < b.name
        end
        return a.total_ms > b.total_ms
    end)
    return { enabled = enabled, sample_limit = sample_limit, interval_ms = interval_ms, stages = rows }
end

function M.report()
    local snapshot = M.snapshot()
    local lines = {
        "Taskbuffer profile (" .. (enabled and "recording" or "stopped") .. "; milliseconds)",
        string.format("%-30s %7s %10s %10s %10s %10s", "stage", "count", "total", "mean", "p95", "max"),
    }
    for _, row in ipairs(snapshot.stages) do
        lines[#lines + 1] = string.format(
            "%-30s %7d %10.3f %10.3f %10.3f %10.3f",
            row.name,
            row.count,
            row.total_ms,
            row.mean_ms,
            row.p95_ms,
            row.max_ms
        )
    end
    lines[#lines + 1] = "Inclusive timings overlap; do not sum rows. p95 uses the latest 256 samples."
    lines[#lines + 1] = "event_loop.delay is editor-wide scheduling delay above a 20 ms interval."
    if #snapshot.stages == 0 then
        lines[#lines + 1] = "No samples. Run :TasksProfile start, exercise tasks, then :TasksProfile stop."
    end
    return table.concat(lines, "\n")
end

-- Set before setup()/plugin loading to capture startup work as well.
if vim.g.taskbuffer_profile == true then
    M.start()
end

return M
