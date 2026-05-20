local opt = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local is_windows = package.config:sub(1,1) == '\\'

package.path = mp.command_native({"expand-path", "~~/script-modules/?.lua;"})..package.path
local input_success, input = pcall(require, "user-input-module")
local menu_input_success, menu_input = pcall(require, "mp.input")

local options = {
    url = "",
    cache_path = "~~cache/jellyfin_client",
    show_by_default = "",
    show_on_idle = "",
    home_latest_limit = 9
}
opt.read_options(options, mp.get_script_name())

options.url = options.url:gsub("/+$", "")
options.home_latest_limit = math.floor(tonumber(options.home_latest_limit) or 9)
if options.home_latest_limit < 1 then options.home_latest_limit = 9 end

if not options.cache_path or options.cache_path == "" then options.cache_path = "~~cache/jellyfin_client" end
options.cache_path = mp.command_native({"expand-path", options.cache_path})
if not options.cache_path or options.cache_path == "" then options.cache_path = mp.command_native({"expand-path", "~~state/jellyfin_client_cache"}) end

local shown = false

local state = {
    user_id = "",
    api_key = "",
    query = "",
    qc_secret = "",
    qc_timer = nil,
    quick_connecting = false,
    layers = {
        { url = "", kind = "root", selection = 1 }
    },
    layer = 1,
    items = {},
    playback_items_by_id = {},
    playback_items_by_path = {},
    playlist_resume_enabled = false,
    last_playback_item = nil,
    last_playback_item_id = "",
    last_position_ticks = nil,
    last_stop_key = "",
    suppress_pause_report = false
}

local mpv_version_str = (mp.get_property("mpv-version") or ""):match("[%d%.]+") or "1.0"

local toggle_menu, close_menu, open_selected_item, go_back_layer, connect, show_menu
local ticks_per_second = 10000000
local resume_min_seconds = 5
local resume_end_threshold_ticks = 60 * ticks_per_second
local client_name = "mpv"
local device_name = "mpv"
local device_id = "mpv-lua"
local request_timeout = 30
local subtitle_timeout = 20
local menu_status_osd_duration = 4

local ItemType = {
    Movie = "Movie", Episode = "Episode", Series = "Series",
    Folder = "Folder", BoxSet = "BoxSet", CollectionFolder = "CollectionFolder"
}

local CollectionType = {
    Movies = "movies", TvShows = "tvshows", Tvs = "tvs"
}

---------------------------------------------------------------------
-- 辅助功能 & 文件操作
---------------------------------------------------------------------

local function current_layer()
    state.layers[state.layer] = state.layers[state.layer] or { url = "", kind = "items", selection = 1 }
    return state.layers[state.layer]
end

local function get_selection()
    return tonumber(current_layer().selection) or 1
end

local function set_selection(index)
    current_layer().selection = index
end

local function get_auth_path()
    return mp.command_native({"expand-path", "~~state/jellyfin_auth.json"})
end

local function safe_json_parse(data)
    if not data or data == "" then return nil end
    local success, result = pcall(utils.parse_json, data)
    if success then return result end
    msg.error("Failed to parse JSON response.")
    return nil
end

local function safe_json_format(data)
    local success, result = pcall(utils.format_json, data)
    if success and result then return result end
    msg.error("Failed to format JSON data.")
    return nil
end

local function load_auth()
    local f = io.open(get_auth_path(), "r")
    if f then
        local content = f:read("*all")
        f:close()
        local data = safe_json_parse(content)
        if data and data.user_id and data.token then
            state.user_id = data.user_id
            state.api_key = data.token
            return true
        end
    end
    return false
end

local function save_auth(uid, token)
    local content = safe_json_format({ user_id = uid, token = token })
    if not content then return end

    local f = io.open(get_auth_path(), "w")
    if not f then
        msg.warn("Failed to save auth to " .. get_auth_path())
        return
    end
    f:write(content)
    f:close()
end

local function clear_auth()
    os.remove(get_auth_path())
    state.user_id = ""
    state.api_key = ""
end

local function url_encode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function api_url(path)
    return options.url .. path
end

local function user_api_path(path)
    return "/Users/" .. state.user_id .. path
end

local function user_api_url(path)
    return api_url(user_api_path(path))
end

local function get_media_source(item)
    if type(item) ~= "table" or type(item.MediaSources) ~= "table" then return nil end

    local selected_id = item.MediaSourceId
    if selected_id and selected_id ~= "" then
        for _, source in ipairs(item.MediaSources) do
            if source and source.Id == selected_id then return source end
        end
    end

    for _, source in ipairs(item.MediaSources) do
        if source and source.Id then return source end
    end

    return item.MediaSources[1]
end

local function get_media_source_id(item)
    if type(item) ~= "table" then return nil end
    local source = get_media_source(item)
    if source and source.Id then return source.Id end
    return item.MediaSourceId
end

local function get_stream_url(item)
    local item_id = type(item) == "table" and item.Id or item
    local url = api_url("/Videos/" .. item_id .. "/stream?static=true")
    local source_id = get_media_source_id(item)
    if source_id == nil or source_id == "" then return url end
    return url .. "&MediaSourceId=" .. url_encode(source_id)
end

local function get_subtitle_url(item_id, source_id, stream_index, ext)
    return api_url("/Videos/" .. item_id .. "/" .. source_id .. "/Subtitles/" .. stream_index .. "/Stream." .. ext)
end

local function ticks_query_value(ticks)
    return string.format("%.0f", math.max(0, tonumber(ticks) or 0))
end

local function quote_header_value(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function auth_part(name, value)
    return name .. '="' .. quote_header_value(value) .. '"'
end

local function get_media_browser_header(include_token)
    local parts = {}
    if include_token and state.api_key ~= "" then
        table.insert(parts, auth_part("Token", state.api_key))
    end
    table.insert(parts, auth_part("Client", client_name))
    table.insert(parts, auth_part("Device", device_name))
    table.insert(parts, auth_part("DeviceId", device_id))
    table.insert(parts, auth_part("Version", mpv_version_str))
    return "Authorization: MediaBrowser " .. table.concat(parts, ", ")
end

local function get_api_auth_header()
    return get_media_browser_header(true)
end

local function get_playback_auth_header()
    if state.api_key == "" then return nil end
    return "Authorization: MediaBrowser " .. auth_part("Token", state.api_key)
end

local function is_playing(item)
    if item.IsFolder then 
        local total = tonumber(item.RecursiveItemCount) or 0
        local unplayed = tonumber(item.UserData.UnplayedItemCount) or 0
        return unplayed > 0 and total - unplayed > 0
    else
        return (tonumber(item and item.UserData and item.UserData.PlaybackPositionTicks) or 0) > 0
    end
end

local function is_played(item)
    return item and item.UserData and item.UserData.Played == true
end

local function get_resume_seconds(item)
    local ticks = tonumber(item and item.UserData and item.UserData.PlaybackPositionTicks) or 0
    if ticks <= 0 or is_played(item) then return nil end

    local runtime_ticks = tonumber(item.RunTimeTicks) or 0
    if runtime_ticks > 0 and runtime_ticks - ticks < resume_end_threshold_ticks then return nil end

    local seconds = math.floor(ticks / ticks_per_second)
    if seconds < resume_min_seconds then return nil end
    return seconds
end

local function get_playback_options(title, item)
    local playback_options = {
        ["force-media-title"] = title,
        ["title"] = title,
        ["osd-playing-msg"] = title,
        ["osd-playlist-entry"] = "title"
    }
    local auth_header = get_playback_auth_header()
    if auth_header then playback_options["http-header-fields"] = auth_header end
    local resume_seconds = get_resume_seconds(item)
    if resume_seconds then playback_options["start"] = tostring(resume_seconds) end
    return playback_options
end

local function safe_filename_part(value)
    local part = tostring(value or ""):gsub("[^%w%-_%.]", "_")
    if part == "" then return "unknown" end
    return part
end

local function clamp(value, min_value, max_value)
    return math.max(min_value, math.min(max_value, value))
end

local function copy_table(values)
    local copied = {}
    for key, value in pairs(values or {}) do
        copied[key] = value
    end
    return copied
end

local function mkdir(path)
    if not path or path == "" then return end
    local args
    if is_windows then
        args = {"cmd", "/d", "/c", "mkdir", path}
    else
        args = {"mkdir", "-p", path}
    end
    mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    })
end

local function build_curl_args(method, url, opts)
    opts = opts or {}
    local args = {"curl", "-sS", "-m", tostring(opts.timeout or request_timeout)}
    if method then
        table.insert(args, "-X")
        table.insert(args, method)
    end
    for _, header in ipairs(opts.headers or {}) do
        table.insert(args, "-H")
        table.insert(args, header)
    end
    if opts.body ~= nil then
        table.insert(args, "-d")
        table.insert(args, opts.body)
    end
    for _, arg in ipairs(opts.extra_args or {}) do
        table.insert(args, arg)
    end
    table.insert(args, url)
    return args
end

local function run_curl(args)
    return mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
        args = args
    })
end

local function run_subprocess(args, stdin_data)
    local success, result = pcall(mp.command_native, {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        stdin_data = stdin_data,
        args = args
    })
    if not success then return nil end
    return result
end

local function powershell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function copy_to_clipboard(text)
    local value = tostring(text or "")
    local commands

    if is_windows then
        commands = {
            {
                args = {"powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Set-Clipboard -Value " .. powershell_quote(value)}
            }
        }
    elseif jit and jit.os == "OSX" then
        commands = {
            { args = {"pbcopy"}, stdin_data = value }
        }
    else
        commands = {
            { args = {"wl-copy"}, stdin_data = value },
            { args = {"xclip", "-selection", "clipboard"}, stdin_data = value },
            { args = {"xsel", "--clipboard", "--input"}, stdin_data = value }
        }
    end

    for _, command in ipairs(commands) do
        local result = run_subprocess(command.args, command.stdin_data)
        if result and result.status == 0 then
            return true
        end
    end

    return false
end

local function split_curl_http_response(stdout)
    local body, code = tostring(stdout or ""):match("^(.*)\n(%d%d%d)$")
    if not body then return stdout or "", nil end
    return body, tonumber(code)
end

local function is_http_success(status)
    return status and status >= 200 and status < 300
end

local function is_auth_error(info)
    return info and (info.status == 401 or info.status == 403)
end

local function send_json_request(method, url, opts)
    opts = opts or {}
    local request_opts = copy_table(opts)
    request_opts.extra_args = copy_table(opts.extra_args)
    table.insert(request_opts.extra_args, "-w")
    table.insert(request_opts.extra_args, "\n%{http_code}")

    local start_time = mp.get_time()
    local request = run_curl(build_curl_args(method, url, request_opts))
    msg.debug(string.format("Waited %.3f seconds for response", mp.get_time() - start_time))

    local info = { url = url, status = nil, curl_status = nil, ok = false }
    if not request then
        msg.warn("Jellyfin API request failed: " .. url)
        return nil, info
    end
    info.curl_status = request.status
    local body, status = split_curl_http_response(request.stdout)
    info.status = status

    if request.status ~= 0 then
        msg.warn("Jellyfin API request failed or timed out: " .. url)
        return nil, info
    end
    if status and not is_http_success(status) then
        msg.warn("Jellyfin API request returned HTTP " .. status .. ": " .. url)
        return nil, info
    end
    if not body or body == "" then
        info.ok = true
        return nil, info
    end

    local parsed = safe_json_parse(body)
    if parsed then info.ok = true else info.parse_failed = true end
    return parsed, info
end

local function send_request(method, url)
    if state.api_key == "" then return nil end
    return send_json_request(method, url, { headers = { get_api_auth_header() } })
end

---------------------------------------------------------------------
-- UI 渲染
---------------------------------------------------------------------

local native_select_session = 0
local deferred_menu_action_timer = nil

local function stop_native_select(terminate_select)
    native_select_session = native_select_session + 1
    if deferred_menu_action_timer then
        deferred_menu_action_timer:kill()
        deferred_menu_action_timer = nil
    end

    if terminate_select ~= false and menu_input_success and menu_input and menu_input.terminate then
        pcall(menu_input.terminate)
    end
end


local function get_watch_prefix(item)
    if not item or item._custom_url or item.Type == "CollectionFolder" or not item.UserData then return "" end
    if is_played(item) then return "✅ " end
    if is_playing(item) then return "🔄 " end
    return "🔲 "
end

local function get_list_text(item)
    if not item then return "" end

    local index = ""
    if not item.IsFolder and item.IndexNumber then
        if item.ParentIndexNumber then
            index = string.format("S%02dE%02d. ", item.ParentIndexNumber, item.IndexNumber)
        else
            index = item.IndexNumber .. ". "
        end
    end

    return get_watch_prefix(item) .. index .. (item.Name or "")
end

local function show_quick_connect_menu(code, status)
    if not menu_input_success or not menu_input or not menu_input.select then
        msg.error("Quick Connect requires native menu support (mp.input.select).")
        return false
    end

    code = tostring(code or "")
    native_select_session = native_select_session + 1
    local session = native_select_session
    local submitted = false
    local submit_status = status
    local reopen_scheduled = false

    local function schedule_reopen()
        if reopen_scheduled then return end
        reopen_scheduled = true
        mp.add_timeout(0.05, function()
            if session ~= native_select_session or not state.quick_connecting then return end
            if not show_quick_connect_menu(code, submit_status) then
                state.qc_secret = ""
                state.quick_connecting = false
                shown = false
            end
        end)
    end

    local ok, err = pcall(menu_input.select, {
        prompt = "快速连接：设置 > 快速连接",
        items = {
            "验证码: " .. code .. (status or "（点击复制）")
        },
        default_item = 1,
        submit = function()
            submitted = true
            submit_status = copy_to_clipboard(code) and "（已复制，等待授权）" or "（复制失败，请手动输入）"
            if menu_input.terminate then pcall(menu_input.terminate) end
            schedule_reopen()
        end,
        closed = function()
            if session ~= native_select_session then return end
            if submitted and state.quick_connecting then
                schedule_reopen()
                return
            end
            close_menu({ terminate_select = false })
        end
    })
    if not ok then
        local message = "Failed to open native quick connect menu: " .. tostring(err)
        msg.error(message)
        return false
    end
    return true
end

show_menu = function()
    if not menu_input_success or not menu_input or not menu_input.select then
        local message = "This mpv build does not support native menus (mp.input.select)."
        msg.error(message)
        close_menu({ terminate_select = false })
        mp.osd_message(message, 5)
        return
    end

    native_select_session = native_select_session + 1
    local session = native_select_session
    local pending_entry = nil
    local finished = false
    local back_offset = state.layer > 1 and 1 or 0

    local function finish_select()
        if finished or session ~= native_select_session then return end
        finished = true

        if pending_entry then
            shown = true
            if pending_entry == 1 and back_offset == 1 then
                go_back_layer()
            elseif state.items[pending_entry - back_offset] then
                set_selection(pending_entry - back_offset)
                open_selected_item()
            end
        else
            close_menu({ terminate_select = false })
        end
    end

    local function defer_finish_select(delay)
        if deferred_menu_action_timer then
            deferred_menu_action_timer:kill()
        end
        deferred_menu_action_timer = mp.add_timeout(delay or 0, function()
            deferred_menu_action_timer = nil
            finish_select()
        end)
    end

    mp.osd_message("", 0)

    local labels = {}
    local default_item = get_selection()

    if back_offset == 1 then
        labels[1] = ".."
        default_item = default_item + 1
    end

    for i, item in ipairs(state.items) do
        labels[i + back_offset] = get_list_text(item):gsub("\\h", " ")
    end
    if #labels == 0 then
        close_menu({ terminate_select = false })
        mp.osd_message("No items found.", menu_status_osd_duration)
        return
    end
    default_item = clamp(default_item, 1, #labels)

    local ok, err = pcall(menu_input.select, {
        prompt = "Jellyfin",
        items = labels,
        default_item = default_item,
        submit = function(index)
            index = tonumber(index)
            if not index or not labels[index] then return end

            pending_entry = index
            if menu_input.terminate then pcall(menu_input.terminate) end
            defer_finish_select(0.05)
        end,
        closed = function()
            if session ~= native_select_session then return end
            defer_finish_select()
        end
    })
    if not ok then
        local message = "Failed to open native menu: " .. tostring(err)
        msg.error(message)
        close_menu({ terminate_select = false })
        mp.osd_message(message, 5)
    end
end

local function add_ids_to_set(set, ids)
    if type(ids) ~= "table" then return end
    for _, id in ipairs(ids) do
        set[id] = true
    end
end

local function fetch_root_menu()
    local new_items = {}
    local excluded_views = {}

    local user_res, user_info = send_request("GET", user_api_url(""))
    local excludes = {}
    if not user_res and is_auth_error(user_info) then return nil, user_info end

    if user_res and user_res.Configuration then
        add_ids_to_set(excludes, user_res.Configuration.LatestItemsExcludes)
        add_ids_to_set(excludes, user_res.Configuration.MyMediaExcludes)
    end

    local views_res, views_info = send_request("GET", user_api_url("/Views"))

    if not views_res or not views_res.Items then return nil, views_info end

    local series_cache, series_names = {}, {}

    local function fetch_series_entries(series_ids)
        local ids = {}
        for id in pairs(series_ids) do
            if not series_cache[id] then table.insert(ids, id) end
        end
        if #ids == 0 then return end

        local series_res = send_request("GET", user_api_url("/Items?Ids=" .. table.concat(ids, ",") .. "&Fields=RecursiveItemCount,ChildCount"))
        if series_res and type(series_res.Items) == "table" then
            for _, item in ipairs(series_res.Items) do
                if item.Id then
                    item.Type = item.Type or "Series"
                    item.IsFolder = true
                    series_cache[item.Id] = item
                end
            end
        end

        for _, id in ipairs(ids) do
            if not series_cache[id] then
                series_cache[id] = { Id = id, Name = series_names[id], Type = "Series", IsFolder = true }
            end
        end
    end

    for _, view in ipairs(views_res.Items) do
        if excludes[view.Id] then
            table.insert(excluded_views, view)
        else
            local url = user_api_url("/Items/Latest?ParentId=" .. view.Id .. "&Fields=RecursiveItemCount,ChildCount&Limit=" .. options.home_latest_limit)
            local res, latest_info = send_request("GET", url)
            if not res and is_auth_error(latest_info) then return nil, latest_info end
            local items = res and (res.Items or res)

            if type(items) == "table" and #items > 0 then
                local item_type = ""
                if view.CollectionType == CollectionType.Movies then
                    item_type = ItemType.Movie
                elseif view.CollectionType == CollectionType.TvShows or view.CollectionType == CollectionType.Tvs then
                    item_type = ItemType.Series
                end

                if item_type == ItemType.Series then
                    local series_ids = {}
                    for i = 1, math.min(options.home_latest_limit, #items) do
                        local item = items[i]
                        if item.Type == ItemType.Episode and item.SeriesId then
                            series_ids[item.SeriesId] = true
                            series_names[item.SeriesId] = series_names[item.SeriesId] or item.SeriesName or item.Name
                        end
                    end
                    fetch_series_entries(series_ids)
                end

                table.insert(new_items, {
                    Name = "新增" .. view.Name,
                    IsFolder = true,
                    _custom_url = user_api_path("/Items?ParentId=" .. view.Id .. "&IncludeItemTypes=" .. item_type .. "&Recursive=true&SortBy=DateCreated&SortOrder=Descending&Fields=RecursiveItemCount,ChildCount")
                })

                for i = 1, math.min(options.home_latest_limit, #items) do
                    local item = items[i]
                    if item_type == ItemType.Series and item.Type == ItemType.Episode then
                        if item.SeriesId then
                            item = series_cache[item.SeriesId]
                        else
                            item = nil
                        end
                    end

                    if item then
                        local display_item = copy_table(item)
                        display_item.IsFolder = display_item.Type == ItemType.Series or
                            display_item.Type == ItemType.Folder or display_item.Type == ItemType.BoxSet
                        display_item.IndexNumber = nil
                        display_item.Name = display_item.Name or ""
                        table.insert(new_items, display_item)
                    end
                end
            end
        end
    end

    table.insert(new_items, {
        Name = "其他",
        IsFolder = true,
        _custom_items = excluded_views
    })

    return new_items
end

local function expand_multipart_items(items)
    if type(items) ~= "table" then return {} end

    local i = 1
    while i <= #items do
        local item = items[i]
        local part_count = item and tonumber(item.PartCount) or 0
        if item and item.Id and part_count > 1 and not item._parts_resolved then
            local part_url = api_url("/Videos/" .. item.Id .. "/AdditionalParts")
            local part_res = send_request("GET", part_url)
            if part_res and type(part_res.Items) == "table" then
                local base_name = item.Name or ""
                item.Name = base_name.." (Part 1)"
                item._parts_resolved = true

                for j, part in ipairs(part_res.Items) do
                    local expanded_item = copy_table(item)
                    expanded_item.Id = part.Id
                    expanded_item.Name = base_name.." (Part "..(j + 1)..")"
                    table.insert(items, i + j, expanded_item)
                end

                i = i + #part_res.Items
            end
        end
        i = i + 1
    end

    return items
end

local function get_item_number(item, field)
    return tonumber(item and item[field])
end

local function sort_episode_items(items)
    if type(items) ~= "table" then return items end

    local original_index = {}
    for i, item in ipairs(items) do
        original_index[item] = i
    end

    table.sort(items, function(a, b)
        local a_played = is_played(a)
        local b_played = is_played(b)
        if a_played ~= b_played then
            return not a_played
        end

        if not a_played then
            local a_date = tostring(a.DateCreated or "")
            local b_date = tostring(b.DateCreated or "")
            if a_date ~= b_date then
                return a_date > b_date
            end
        end

        local a_season = get_item_number(a, "ParentIndexNumber") or 0
        local b_season = get_item_number(b, "ParentIndexNumber") or 0
        if a_season ~= b_season then
            return a_season > b_season
        end

        local a_episode = get_item_number(a, "IndexNumber") or 0
        local b_episode = get_item_number(b, "IndexNumber") or 0
        if a_episode ~= b_episode then
            return a_episode > b_episode
        end

        return (original_index[a] or 0) < (original_index[b] or 0)
    end)

    return items
end

local function update_menu(opts)
    if state.quick_connecting then return end
    opts = opts or {}
    local layer = current_layer()
    local old_items = (type(state.items) == "table") and state.items or {}
    local previous_selection = get_selection()
    local previous_item = opts.preserve_selection and old_items[previous_selection] or nil
    local previous_id = previous_item and previous_item.Id

    mp.osd_message("Loading...", request_timeout + 1)

    local url = ""
    local is_root = false

    if state.query ~= "" then
        url = user_api_url("/Items?searchTerm=" .. state.query .. "&Recursive=true&Fields=RecursiveItemCount,ChildCount")
    elseif state.layer == 1 then
        is_root = true
    else
        url = api_url(layer.url or "")
    end

    local function handle_fetch_error(info)
        if is_auth_error(info) and state.api_key ~= "" then
            msg.warn("Jellyfin token was rejected. Reconnecting...")
            clear_auth()
            connect()
            return
        end

        shown = false
        if info and info.status == 503 then
            mp.osd_message("Jellyfin is starting or temporarily unavailable.", menu_status_osd_duration)
        elseif info and info.status and info.status >= 500 then
            mp.osd_message("Jellyfin server error. Try again later.", menu_status_osd_duration)
        else
            mp.osd_message("Connection Failed. Check URL or Network.", menu_status_osd_duration)
        end
    end

    if is_root then
        local root_items, root_info = fetch_root_menu()
        if not root_items then handle_fetch_error(root_info); return end
        state.items = root_items
    elseif layer.items then
        state.items = copy_table(layer.items)
    else
        local json, request_info = send_request("GET", url)
        if not json then handle_fetch_error(request_info); return end
        state.items = json.Items or json
        if type(state.items) ~= "table" then state.items = {} end
    end
    state.items = expand_multipart_items(state.items)
    if state.query == "" and layer.kind == "episodes" then
        state.items = sort_episode_items(state.items)
    end

    if state.items and #state.items > 0 then
        local restored_selection = previous_selection
        if previous_id then
            for i, item in ipairs(state.items) do
                if item.Id == previous_id then
                    restored_selection = i
                    break
                end
            end
        end
        set_selection(clamp(restored_selection, 1, #state.items))
        show_menu()
    else
        set_selection(1)
        if state.layer > 1 then
            show_menu()
        else
            shown = false
            mp.osd_message("No items found.", menu_status_osd_duration)
        end
    end
end

---------------------------------------------------------------------
-- 交互与控制逻辑
---------------------------------------------------------------------

local function get_item_title(item)
    if not item then return "" end
    local name = item.Name or ""
    if item.SeriesName then
        local season = item.ParentIndexNumber and string.format("S%02d", item.ParentIndexNumber) or ""
        local episode = item.IndexNumber and string.format("E%02d", item.IndexNumber) or ""
        local se = season .. episode
        if se ~= "" then
            return string.format("%s - %s - %s", item.SeriesName, se, name)
        end
        return string.format("%s - %s", item.SeriesName, name)
    end
    return name
end

local function clean_playlist_display_path(value)
    local path = tostring(value or ""):gsub("[\r\n]", " ")
    path = path:gsub("[\\/:%*%?\"<>|]", "-"):gsub("%s+", " ")
    path = path:gsub("^%s+", ""):gsub("%s+$", "")
    if path == "" then return "Jellyfin item" end
    return path
end

local function get_unique_playlist_display_path(item, used_paths)
    used_paths = used_paths or {}
    local base_path = clean_playlist_display_path(get_item_title(item))
    local path = base_path
    local index = 2

    while used_paths[path] do
        path = base_path .. " (" .. tostring(index) .. ")"
        index = index + 1
    end

    used_paths[path] = true
    return path
end

local function load_video_item(item, mode, playlist_path)
    local title = get_item_title(item)
    -- Queued episodes use title-like paths for playlist display; on_load rewrites them to real URLs.
    if playlist_path then state.playback_items_by_path[playlist_path] = item end
    mp.command_native({"loadfile", playlist_path or get_stream_url(item), mode, -1, get_playback_options(title, item)})
end

local function get_playback_item_by_playlist_path(path)
    if not path then return nil end
    local basename = tostring(path):match("[^\\/]+$")
    return state.playback_items_by_path[path] or (basename and state.playback_items_by_path[basename])
end

local function remember_playback_items(items)
    state.playback_items_by_id = {}
    state.playback_items_by_path = {}
    for _, item in ipairs(items or {}) do
        if item and item.Id then
            state.playback_items_by_id[item.Id] = item
        end
    end
end

local function is_episode_like_item(item)
    return item and (item.Type == ItemType.Episode or item.SeriesId or item.SeriesName or
        item.ParentIndexNumber or current_layer().kind == "episodes")
end

local function is_same_episode_series(item, selected_item)
    if not item or not selected_item then return false end
    if item.Id == selected_item.Id then return true end
    if selected_item.SeriesId and item.SeriesId then return item.SeriesId == selected_item.SeriesId end
    if selected_item.SeriesName and item.SeriesName then return item.SeriesName == selected_item.SeriesName end
    return current_layer().kind == "episodes"
end

local function is_following_episode(item, selected_item, item_index, selected_index)
    local selected_season = get_item_number(selected_item, "ParentIndexNumber")
    local selected_episode = get_item_number(selected_item, "IndexNumber")
    local item_season = get_item_number(item, "ParentIndexNumber")
    local item_episode = get_item_number(item, "IndexNumber")

    if selected_season and selected_episode and item_season and item_episode then
        if item_season ~= selected_season then return item_season > selected_season end
        if item_episode ~= selected_episode then return item_episode > selected_episode end
        return item_index >= selected_index
    end

    return item_index >= selected_index
end

local function compare_episode_order(original_index)
    return function(a, b)
        local a_season = get_item_number(a, "ParentIndexNumber") or math.huge
        local b_season = get_item_number(b, "ParentIndexNumber") or math.huge
        if a_season ~= b_season then return a_season < b_season end

        local a_episode = get_item_number(a, "IndexNumber") or math.huge
        local b_episode = get_item_number(b, "IndexNumber") or math.huge
        if a_episode ~= b_episode then return a_episode < b_episode end

        return (original_index[a] or 0) < (original_index[b] or 0)
    end
end

local function build_episode_playlist_from_current_menu(selected_index, selected_item)
    if not selected_item or selected_item.IsFolder or not selected_item.Id then return nil end
    if not is_episode_like_item(selected_item) then return nil end

    local original_index = {}
    local playlist_items = {}
    for i, item in ipairs(state.items or {}) do
        if item and item.Id and not item.IsFolder and
            is_same_episode_series(item, selected_item) and
            is_following_episode(item, selected_item, i, selected_index) then
            original_index[item] = i
            table.insert(playlist_items, item)
        end
    end
    if #playlist_items == 0 then return nil end
    table.sort(playlist_items, compare_episode_order(original_index))
    return playlist_items
end

local function play_video()
    local selected_index = get_selection()
    local item = state.items[selected_index]
    if not item or not item.Id then return end

    toggle_menu()
    mp.commandv("playlist-play-index", "none")
    mp.command("playlist-clear")

    local episode_playlist_items = build_episode_playlist_from_current_menu(selected_index, item)
    if episode_playlist_items then
        remember_playback_items(episode_playlist_items)
        state.playlist_resume_enabled = true
        local used_paths = {}
        for i, episode in ipairs(episode_playlist_items) do
            load_video_item(episode, i == 1 and "replace" or "append", get_unique_playlist_display_path(episode, used_paths))
        end
        msg.debug(string.format("Queued %d Jellyfin episode playlist items from current menu.", #episode_playlist_items))
        return
    end

    remember_playback_items({ item })
    state.playlist_resume_enabled = false
    load_video_item(item, "replace")
end

open_selected_item = function()
    local item = state.items[get_selection()]
    if not item then return end
    if item.IsFolder == false then
        play_video()
        return
    end

    state.layer = state.layer + 1
    local layer = current_layer()
    layer.kind = "items"

    if item._custom_url then
        layer.url = item._custom_url
    elseif item._custom_items then
        layer.items = item._custom_items
    elseif item.Type == ItemType.Series then
        layer.kind = "episodes"
        layer.url = user_api_path("/Items?ParentId=" .. item.Id .. "&IncludeItemTypes=Episode&Recursive=true&SortBy=ParentIndexNumber,IndexNumber&SortOrder=Descending")
    else
        layer.url = user_api_path("/Items?ParentId=" .. item.Id .. "&SortBy=DateCreated&SortOrder=Descending&Fields=RecursiveItemCount,ChildCount")
    end

    layer.selection = 1
    state.query = ""
    update_menu()
end

go_back_layer = function()
    if state.layer <= 1 then return end
    state.layers[state.layer] = nil
    state.layer = state.layer - 1
    state.query = ""
    update_menu()
end

connect = function()
    local res = send_json_request("POST", api_url("/QuickConnect/Initiate"), {
        headers = { "Content-Length: 0", get_media_browser_header(false) }
    })
    if not res or not res.Code or not res.Secret then
        shown = false
        mp.osd_message("Jellyfin 快速连接失败，请检查 URL。", 6)
        return
    end

    state.qc_secret = res.Secret
    state.quick_connecting = true
    if not show_quick_connect_menu(res.Code) then
        state.qc_secret = ""
        state.quick_connecting = false
        shown = false
        return
    end

    if state.qc_timer then state.qc_timer:kill() end
    state.qc_timer = mp.add_periodic_timer(3, function()
        local check_res = send_json_request("GET", api_url("/QuickConnect/Connect?secret=" .. url_encode(state.qc_secret)))
        if not (check_res and check_res.Authenticated) then return end

        if state.qc_timer then state.qc_timer:kill() end
        state.qc_timer = nil

        local body = safe_json_format({ Secret = state.qc_secret })
        local auth_res = body and send_json_request("POST", api_url("/Users/AuthenticateWithQuickConnect"), {
            headers = { "Content-Type: application/json", get_media_browser_header(false) },
            body = body
        })
        if auth_res and auth_res.AccessToken and auth_res.User then
            state.user_id = auth_res.User.Id
            state.api_key = auth_res.AccessToken
            state.quick_connecting = false
            save_auth(state.user_id, state.api_key)
            stop_native_select(true)
            mp.add_timeout(0.05, function()
                if state.api_key ~= "" and not state.quick_connecting then
                    update_menu()
                end
            end)
            return
        end

        state.quick_connecting = false
        stop_native_select(true)
        shown = false
        mp.osd_message("Jellyfin 授权成功，但登录令牌交换失败。", 6)
    end)
end

close_menu = function(opts)
    opts = opts or {}
    stop_native_select(opts.terminate_select)

    if state.qc_timer then
        state.qc_timer:kill()
        state.qc_timer = nil
        state.quick_connecting = false
        mp.osd_message("", 0)
    end
    shown = false
end

toggle_menu = function()
    if shown then
        close_menu()
        return
    end

    shown = true
    if state.api_key == "" and not load_auth() then
        connect()
    else
        update_menu({ preserve_selection = true })
    end
end

---------------------------------------------------------------------
-- 播放器事件集成
---------------------------------------------------------------------

local function resolve_jellyfin_playlist_path()
    local path = mp.get_property("stream-open-filename") or mp.get_property("path")
    local item = get_playback_item_by_playlist_path(path)
    if item and item.Id then
        mp.set_property("stream-open-filename", get_stream_url(item))
    end
end

local function get_playing_item()
    local path = mp.get_property("path")
    if not path then return nil end

    local playback_item = get_playback_item_by_playlist_path(path)
    if playback_item then return playback_item end

    local video_id = path:match("/Videos/([^/%?#]+)/stream")
    if not video_id then return nil end

    playback_item = state.playback_items_by_id[video_id]
    if playback_item then return playback_item end

    for _, item in ipairs(state.items) do
        if item.Id == video_id then return item end
    end
    return nil
end

local function get_position_ticks(prefer_duration)
    if prefer_duration then
        local duration = mp.get_property_number("duration")
        if duration and duration >= 0 then return math.floor(duration * ticks_per_second) end
    end

    local time_pos = mp.get_property_number("time-pos")
    if time_pos and time_pos >= 0 then return math.floor(time_pos * ticks_per_second) end

    return nil
end

local function get_playback_report(prefer_duration)
    local item = get_playing_item()
    local ticks = get_position_ticks(prefer_duration)

    if not item and state.last_playback_item then item = state.last_playback_item end
    if item and not ticks and state.last_playback_item_id == item.Id then ticks = state.last_position_ticks end
    if not item or not ticks then return nil, nil end

    state.last_playback_item = item
    state.last_playback_item_id = item.Id
    state.last_position_ticks = ticks
    return item, ticks
end

local function get_playback_base_body(item, ticks)
    local body = {
        ItemId = item.Id,
        PositionTicks = math.floor(math.max(0, tonumber(ticks) or 0))
    }

    local media_source_id = get_media_source_id(item)
    if media_source_id and media_source_id ~= "" then body.MediaSourceId = media_source_id end
    return body
end

local function get_playback_state_body(item, ticks, is_paused)
    local body = get_playback_base_body(item, ticks)
    body.CanSeek = true
    body.IsPaused = is_paused == true
    body.IsMuted = mp.get_property_bool("mute") == true
    body.PlayMethod = "DirectPlay"
    return body
end

local function get_playback_stop_body(item, ticks, event)
    local body = get_playback_base_body(item, ticks)
    body.Failed = event and event.reason == "error" or false
    return body
end

local function playback_request_failed(success, result)
    if not success or not result or result.status ~= 0 then return true end
    local _, status = split_curl_http_response(result.stdout)
    return status and not is_http_success(status)
end

local function send_playback_request(endpoint, body, sync)
    local content = safe_json_format(body)
    if not content then return end

    local args = build_curl_args("POST", api_url(endpoint), {
        timeout = sync and 3 or request_timeout,
        headers = { "Content-Type: application/json", get_api_auth_header() },
        body = content,
        extra_args = { "-w", "\n%{http_code}" }
    })

    if sync then
        local result = run_curl(args)
        if playback_request_failed(result ~= nil, result) then
            msg.debug("Playback report failed: " .. endpoint)
        end
        return
    end

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }, function(success, result)
        if playback_request_failed(success, result) then
            msg.debug("Playback report failed: " .. endpoint)
        end
    end)
end

local function send_jellyfin_started(sync)
    if state.api_key == "" or state.user_id == "" then return end

    local item, ticks = get_playback_report(false)
    if not item then return end

    local is_paused = mp.get_property_bool("pause") == true
    state.last_stop_key = ""
    send_playback_request("/Sessions/Playing", get_playback_state_body(item, ticks, is_paused), sync)
end

local function send_jellyfin_progress(is_paused, sync)
    if state.api_key == "" or state.user_id == "" then return end

    local item, ticks = get_playback_report(false)
    if not item then return end

    if is_paused == nil then is_paused = mp.get_property_bool("pause") == true end
    state.last_stop_key = ""
    send_playback_request("/Sessions/Playing/Progress", get_playback_state_body(item, ticks, is_paused), sync)
end

local function send_jellyfin_stopped(event, sync)
    if state.api_key == "" or state.user_id == "" then return end

    local item, ticks = get_playback_report(event and event.reason == "eof")
    if not item then return end

    local stop_key = item.Id .. ":" .. ticks_query_value(ticks)
    if state.last_stop_key == stop_key then return end
    state.last_stop_key = stop_key

    send_playback_request("/Sessions/Playing/Stopped", get_playback_stop_body(item, ticks, event), sync)
end

local function download_and_add_subtitle(item, source, stream, ext)
    if state.api_key == "" then return end

    local subtitle_dir = options.cache_path .. "/subtitles"
    mkdir(subtitle_dir)

    local safe_ext = safe_filename_part(ext)
    if safe_ext == "unknown" then safe_ext = "srt" end
    local filepath = subtitle_dir .. "/" .. safe_filename_part(item.Id) .. "_" ..
        safe_filename_part(source.Id) .. "_" .. safe_filename_part(stream.Index) .. "." .. safe_ext
    local url = get_subtitle_url(item.Id, source.Id, stream.Index, ext)
    local expected_item_id = item.Id
    local title = stream.DisplayTitle
    local language = stream.Language

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = build_curl_args(nil, url, {
            timeout = subtitle_timeout,
            headers = { get_api_auth_header() },
            extra_args = { "-L", "-f", "-o", filepath }
        })
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            msg.warn("Failed to download Jellyfin subtitle: " .. url)
            return
        end
        local current_item = get_playing_item()
        if current_item and current_item.Id == expected_item_id then
            mp.commandv("sub-add", filepath, "auto", title, language)
        end
    end)
end

local function add_subs()
    local item = get_playing_item()
    if not item or not item.MediaSources then return end

    local source = get_media_source(item)
    if not source or not source.MediaStreams then
        for _, candidate in ipairs(item.MediaSources) do
            if candidate and candidate.MediaStreams then
                source = candidate
                break
            end
        end
    end
    if not source or not source.Id or not source.MediaStreams then return end

    for _, stream in ipairs(source.MediaStreams) do
        if stream.IsTextSubtitleStream and stream.IsExternal then
            local ext = (stream.Path and stream.Path:match(".+%.([^.]+)$")) or "srt"
            download_and_add_subtitle(item, source, stream, ext)
        end
    end
end

local function apply_playlist_resume()
    if not state.playlist_resume_enabled then return end

    local item = get_playing_item()
    local resume_seconds = get_resume_seconds(item)
    if resume_seconds then mp.commandv("seek", resume_seconds, "absolute", "exact") end
end

local function on_file_loaded()
    apply_playlist_resume()
    send_jellyfin_started()
    add_subs()
end

local function unpause()
    if not mp.get_property_bool("pause") then return end
    state.suppress_pause_report = true
    mp.set_property_bool("pause", false)
end

local function on_pause_change(_, is_paused)
    if state.suppress_pause_report then
        state.suppress_pause_report = false
        return
    end
    if is_paused ~= nil then send_jellyfin_progress(is_paused) end
end

local function on_end_file(event)
    send_jellyfin_stopped(event, event and event.reason == "quit")
    if event and event.reason == "eof" then unpause() end
end

local function on_shutdown()
    send_jellyfin_stopped(nil, true)
end

local function search(query)
    if not query or query == "" then return end
    if shown then close_menu() end
    state.query = url_encode(query)
    state.items = {}
    toggle_menu()
end

local major, minor = mpv_version_str:match("(%d+)%.(%d+)")
local is_supported_version = tonumber(major) ~= 0 or tonumber(minor) >= 38

if not is_supported_version then
    msg.error("Minimum mpv version (0.38.0) not met for mpv-jellyfin script.")
else
    mp.observe_property("pause", "bool", on_pause_change)
    mp.register_event("seek", function() send_jellyfin_progress() end)
    mp.add_periodic_timer(10, function() if not mp.get_property_bool("pause") then send_jellyfin_progress() end end)

    mp.add_key_binding("Ctrl+j", "jf", toggle_menu)
    mp.add_key_binding("ESC", "jf_close", function() if shown then close_menu() end end)

    mkdir(options.cache_path)
    mp.add_hook("on_load", 50, resolve_jellyfin_playlist_path)
    mp.register_event("end-file", on_end_file)
    mp.register_event("shutdown", on_shutdown)
    mp.register_event("file-loaded", on_file_loaded)

    if input_success then mp.add_key_binding("Ctrl+f", "jf_search", function() input.get_user_input(search) end) end
    if options.show_by_default == "on" then toggle_menu() end
    if options.show_on_idle == "on" then
        mp.observe_property("idle-active", "bool", function(_, is_idle) if is_idle and not shown then toggle_menu() end end)
    end
end
