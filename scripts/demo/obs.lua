-- Load in OBS via Tools > Scripts. No websocket server or global key injection.
local obs = obslua
local control, scene = "", "Taskbuffer demo"
local owned, pending, stopped, last_request = nil, nil, nil, nil

local function read_state()
    local file = io.open(control, "r")
    if not file then
        return
    end
    local text = file:read("*a")
    file:close()
    local data = obs.obs_data_create_from_json(text)
    if not data then
        return
    end
    local result = {
        run_id = obs.obs_data_get_string(data, "run_id"),
        status = obs.obs_data_get_string(data, "status"),
        record = obs.obs_data_get_bool(data, "record"),
        heartbeat = obs.obs_data_get_int(data, "heartbeat"),
    }
    obs.obs_data_release(data)
    return result
end

local function acknowledge(id, status, err)
    local data = obs.obs_data_create()
    obs.obs_data_set_string(data, "run_id", id)
    obs.obs_data_set_string(data, "status", status)
    if err then
        obs.obs_data_set_string(data, "error", err)
    end
    local temporary = control .. ".obs.tmp"
    local file = io.open(temporary, "w")
    if file then
        file:write(obs.obs_data_get_json(data))
        file:close()
        os.rename(temporary, control .. ".obs.json")
    end
    obs.obs_data_release(data)
end

local function stop_owned()
    if owned then
        stopped = owned
        owned, pending = nil, nil
        obs.obs_frontend_recording_stop()
    end
end

local function poll()
    if control == "" then
        return
    end
    if stopped then
        if obs.obs_frontend_recording_active() then
            return
        end
        acknowledge(stopped, "stopped")
        stopped = nil
    end
    local state = read_state()
    if not state or os.time() - state.heartbeat > 10 then
        stop_owned()
        return
    end
    if owned then
        if
            state.run_id ~= owned
            or state.status == "complete"
            or state.status == "aborted"
            or state.status == "error"
            or state.status == "closed"
        then
            stop_owned()
        elseif pending then
            if obs.obs_frontend_recording_active() then
                pending = nil
                acknowledge(owned, "recording")
            elseif os.time() - pending > 10 then
                local id = owned
                stop_owned()
                stopped = nil
                acknowledge(id, "error", "OBS could not start recording; check its output settings")
            end
        elseif not obs.obs_frontend_recording_active() then
            acknowledge(owned, "error", "Recording was stopped in OBS")
            owned = nil
        end
        return
    end
    if not state.record or state.status ~= "record-request" or state.run_id == last_request then
        return
    end
    last_request = state.run_id
    if obs.obs_frontend_recording_active() or obs.obs_frontend_streaming_active() then
        acknowledge(state.run_id, "error", "OBS is already recording or streaming; finish that session first")
        return
    end
    local source = obs.obs_get_source_by_name(scene)
    if not source then
        acknowledge(state.run_id, "error", "Create the OBS scene '" .. scene .. "' and add the demo window capture")
        return
    end
    obs.obs_frontend_set_current_scene(source)
    obs.obs_source_release(source)
    owned, pending = state.run_id, os.time()
    obs.obs_frontend_recording_start()
end

function script_description()
    return "Record taskbuffer's scripted demo. Select its control.json and a scene containing only the demo window. "
        .. "Launch scripts/demo.py --record, then press F5 in Neovim. This script never starts a stream."
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_path(props, "control", "Demo control.json", obs.OBS_PATH_FILE, "JSON (*.json)", nil)
    obs.obs_properties_add_text(props, "scene", "Capture scene", obs.OBS_TEXT_DEFAULT)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "scene", "Taskbuffer demo")
end

function script_update(settings)
    local next_control = obs.obs_data_get_string(settings, "control")
    local next_scene = obs.obs_data_get_string(settings, "scene")
    if next_control ~= control or next_scene ~= scene then
        stop_owned()
        last_request = nil
    end
    control, scene = next_control, next_scene
end

function script_load()
    obs.timer_add(poll, 100)
end

function script_unload()
    obs.timer_remove(poll)
    stop_owned()
end
