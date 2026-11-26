-- Dot-repeat for task actions. A mapping arms 'operatorfunc' and returns `g@l`;
-- Neovim records `g@l` as the last change, so `.` re-runs the same action at
-- the cursor's new position, exactly as if the mapping were pressed again.
-- Loaded on the first keypress, never at startup.
local M = {}

local action_pending

local OPERATORFUNC = "v:lua.require'taskbuffer.dotrepeat'.operatorfunc"

function M.operatorfunc()
    if not action_pending then
        return
    end
    action_pending()
end

--- Arm `action` for the operator and return the keys an expr mapping feeds.
---@param action fun()
---@return string
function M.arm(action)
    action_pending = action
    vim.go.operatorfunc = OPERATORFUNC
    return "g@l"
end

--- Set a normal-mode mapping whose action `.` repeats.
---@param lhs string
---@param action fun()
---@param opts table|nil
function M.map(lhs, action, opts)
    opts = vim.tbl_extend("force", opts or {}, { expr = true })
    vim.keymap.set("n", lhs, function()
        return M.arm(action)
    end, opts)
end

return M
