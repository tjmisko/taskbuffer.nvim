-- Protocol tests for the actual OBS script, without a capture device or OBS GUI.
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local path = directory .. "/control.json"
local recording, streaming, scene_exists = false, false, true
local starts, stops, tick = 0, 0, nil
local function put(id, status, record, heartbeat)
    vim.fn.writefile({
        vim.json.encode({
            run_id = id,
            status = status,
            record = record ~= false,
            heartbeat = heartbeat or os.time(),
        }),
    }, path)
end
local function ack()
    return vim.json.decode(table.concat(vim.fn.readfile(path .. ".obs.json"), "\n"))
end
local function get(data, key)
    return data[key]
end
local function set(data, key, value)
    data[key] = value
end
_G.obslua = {
    obs_data_create_from_json = vim.json.decode,
    obs_data_create = function()
        return {}
    end,
    obs_data_get_string = get,
    obs_data_get_bool = get,
    obs_data_get_int = get,
    obs_data_set_string = set,
    obs_data_set_default_string = set,
    obs_data_get_json = vim.json.encode,
    obs_data_release = function() end,
    obs_frontend_recording_active = function()
        return recording
    end,
    obs_frontend_streaming_active = function()
        return streaming
    end,
    obs_frontend_recording_start = function()
        starts = starts + 1
        recording = true
    end,
    obs_frontend_recording_stop = function()
        stops = stops + 1
        recording = false
    end,
    obs_get_source_by_name = function()
        return scene_exists and {} or nil
    end,
    obs_frontend_set_current_scene = function() end,
    obs_source_release = function() end,
    timer_add = function(fn)
        tick = fn
    end,
    timer_remove = function() end,
}
dofile("scripts/demo/obs.lua")
script_update({ control = path, scene = "Taskbuffer demo" })
script_load()

-- A normal request is acknowledged only after recording becomes active.
put("one", "record-request")
tick()
assert(starts == 1 and recording)
tick()
assert(ack().run_id == "one" and ack().status == "recording")
put("one", "complete")
tick()
tick()
assert(stops == 1 and not recording and ack().status == "stopped")
tick()
assert(starts == 1)

-- Never take over an unrelated recording or stream.
recording = true
put("two", "record-request")
tick()
assert(ack().error and starts == 1 and stops == 1 and recording)
recording, streaming = false, true
put("three", "record-request")
tick()
assert(ack().error and starts == 1)
streaming, scene_exists = false, false
put("four", "record-request")
tick()
assert(ack().error and starts == 1)
scene_exists = true

-- Replay, abort, exit, and a crashed player all release an owned recording.
for index, status in ipairs({ "aborted", "closed", "error", "stale" }) do
    local id = "stop-" .. index
    put(id, "record-request")
    tick()
    tick()
    assert(ack().run_id == id and recording)
    put(id, status, true, status == "stale" and os.time() - 30 or nil)
    tick()
    tick()
    assert(not recording and ack().status == "stopped")
end
local previous_starts = starts
put("manual", "record-request", false)
tick()
assert(starts == previous_starts)
recording = true
script_unload()
assert(recording, "unloading must not stop an unrelated recording")
print("OBS protocol passed: start acknowledgement, replay, abort, exit, stale heartbeat, and recording ownership")
vim.fn.delete(directory, "rf")
