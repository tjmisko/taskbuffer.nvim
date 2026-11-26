-- Copy user extended attributes between files via LuaJIT FFI.
-- Best effort: any missing capability degrades to "nothing copied".
local M = {}

local PREFIX = "user."

local state -- nil = uninitialized, false = unavailable, table = bindings

local function bindings()
    if state ~= nil then
        return state
    end
    state = false
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then
        return state
    end
    local darwin = vim.uv.os_uname().sysname == "Darwin"
    local declared = pcall(ffi.cdef, darwin and [[
            long listxattr(const char *path, char *list, size_t size, int options);
            long getxattr(const char *path, const char *name, void *value, size_t size, uint32_t position, int options);
            int setxattr(const char *path, const char *name, const void *value, size_t size, uint32_t position, int options);
        ]] or [[
            long listxattr(const char *path, char *list, size_t size);
            long getxattr(const char *path, const char *name, void *value, size_t size);
            int setxattr(const char *path, const char *name, const void *value, size_t size, int flags);
        ]])
    if not declared then
        return state
    end
    local C = ffi.C
    local ok_symbol = pcall(function()
        return C.listxattr, C.getxattr, C.setxattr
    end)
    if not ok_symbol then
        return state
    end
    state = {
        ffi = ffi,
        list = function(path, buf, size)
            if darwin then
                return C.listxattr(path, buf, size, 0)
            end
            return C.listxattr(path, buf, size)
        end,
        get = function(path, name, buf, size)
            if darwin then
                return C.getxattr(path, name, buf, size, 0, 0)
            end
            return C.getxattr(path, name, buf, size)
        end,
        set = function(path, name, value, size)
            if darwin then
                return C.setxattr(path, name, value, size, 0, 0)
            end
            return C.setxattr(path, name, value, size, 0)
        end,
    }
    return state
end

local function user_names(api, path)
    local size = tonumber(api.list(path, nil, 0))
    if not size or size <= 0 then
        return {}
    end
    local buf = api.ffi.new("char[?]", size)
    local got = tonumber(api.list(path, buf, size))
    if not got or got <= 0 then
        return {}
    end
    local names = {}
    for name in api.ffi.string(buf, got):gmatch("%z?([^%z]+)") do
        if name:sub(1, #PREFIX) == PREFIX then
            names[#names + 1] = name
        end
    end
    return names
end

-- Returns the number of attributes copied. Never raises.
function M.copy_user(from, to)
    local api = bindings()
    if not api then
        return 0
    end
    local ok, copied = pcall(function()
        local count = 0
        for _, name in ipairs(user_names(api, from)) do
            local size = tonumber(api.get(from, name, nil, 0))
            if size and size >= 0 then
                local buf = api.ffi.new("char[?]", math.max(size, 1))
                local got = tonumber(api.get(from, name, buf, size))
                if got and got >= 0 and api.set(to, name, buf, got) == 0 then
                    count = count + 1
                end
            end
        end
        return count
    end)
    return ok and copied or 0
end

return M
