-- Cooperative CPU work, active only while processing a requested task operation.
local M = {}
local profile = require("taskbuffer.profile")
local active

function M.context()
    return active
end

function M.checkpoint()
    if not active then
        return
    end
    active.iterations = active.iterations + 1
    if active.iterations % 32 == 0 and vim.uv.hrtime() >= active.deadline then
        coroutine.yield()
    end
end

-- fn may yield via checkpoint(); callbacks always run on the main loop.
-- Cancelling stops subsequent slices and suppresses the completion callback.
function M.run(fn, cb)
    local thread = coroutine.create(fn)
    local state = { iterations = 0 }
    local cancelled = false
    local timer
    local function step()
        timer = nil
        if cancelled then
            return
        end
        state.deadline = vim.uv.hrtime() + 4e6
        local previous = active
        active = state
        local span = profile.begin("async.slice")
        local ok, value, err = coroutine.resume(thread)
        profile.finish(span)
        active = previous
        if not ok then
            cb(nil, tostring(value))
        elseif coroutine.status(thread) == "dead" then
            cb(value, err)
        else
            -- A timer lets input/redraw run between slices, even if Neovim is
            -- draining its scheduled-callback queue.
            timer = vim.defer_fn(step, 1)
        end
    end
    vim.schedule(step)
    return function()
        cancelled = true
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
    end
end

-- table.sort cannot yield through its C comparator. Merge sort can.
function M.sort(items, less)
    if not active then
        table.sort(items, less)
        return
    end
    local scratch = {}
    local width = 1
    while width < #items do
        for start = 1, #items, 2 * width do
            local middle = math.min(start + width, #items + 1)
            local last = math.min(start + 2 * width - 1, #items)
            local left, right = start, middle
            for target = start, last do
                M.checkpoint()
                if left < middle and (right > last or not less(items[right], items[left])) then
                    scratch[target] = items[left]
                    left = left + 1
                else
                    scratch[target] = items[right]
                    right = right + 1
                end
            end
            for target = start, last do
                M.checkpoint()
                items[target] = scratch[target]
            end
        end
        width = width * 2
    end
end

return M
