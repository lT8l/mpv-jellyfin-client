local options_module = require "mp.options"
local utils = require "mp.utils"
local msg = require "mp.msg"
local input = require "mp.input"

local options = {
    url = "",
    cache_path = "~~cache/jellyfin_client",
    show_by_default = "",
    show_on_idle = "",
    home_latest_limit = 9,
    page_size = 100,
}

options_module.read_options(options, mp.get_script_name())

options.url = tostring(options.url or ""):gsub("/+$", "")
options.home_latest_limit = math.floor(tonumber(options.home_latest_limit) or 9)
options.page_size = math.floor(tonumber(options.page_size) or 100)
if options.home_latest_limit < 1 then options.home_latest_limit = 9 end
if options.page_size < 1 then options.page_size = 100 end
if not options.cache_path or options.cache_path == "" then
    options.cache_path = "~~cache/jellyfin_client"
end
options.cache_path = mp.command_native({ "expand-path", options.cache_path })

local TICKS_PER_SECOND = 10000000
local REQUEST_TIMEOUT = 30
local SUBTITLE_TIMEOUT = 20
local CLIENT_NAME = "mpv-jellyfin"
local CLIENT_VERSION = "2.0"
local DEVICE_NAME = "mpv"
local AUTH_VERSION = 3

local folder_types = {
    Series = true,
    Season = true,
    Folder = true,
    BoxSet = true,
    CollectionFolder = true,
    MusicAlbum = true,
    MusicArtist = true,
    MusicGenre = true,
    PhotoAlbum = true,
    Playlist = true,
    PlaylistsFolder = true,
}

local video_types = {
    Movie = true,
    Episode = true,
    Video = true,
    MusicVideo = true,
    Trailer = true,
}

local audio_types = {
    Audio = true,
    AudioBook = true,
}

local photo_types = {
    Photo = true,
}

local unsupported_leaf_types = {
    Book = true,
    LiveTvProgram = true,
    Program = true,
    Recording = true,
    TvProgram = true,
}

local all_include_types = table.concat({
    "Movie", "Episode", "Series", "Season", "Video", "MusicVideo", "Trailer",
    "Audio", "AudioBook", "MusicAlbum", "MusicArtist", "MusicGenre",
    "Photo", "PhotoAlbum", "Playlist", "PlaylistsFolder",
    "Folder", "BoxSet", "CollectionFolder", "LiveTvChannel",
}, ",")

local state = {
    auth = {
        device_id = "",
        user_id = "",
        access_token = "",
    },
    shown = false,
    layers = {
        { kind = "root", title = "Jellyfin", selection = 1 },
    },
    entries = {},
    menu_generation = 0,
    menu_requests = {},
    select_session = 0,
    quick = {
        generation = 0,
        active = false,
        polling = false,
        requests = {},
        timer = nil,
        secret = "",
    },
    preparing_generation = 0,
    preparing_requests = {},
    playback = {
        planned = {},
        live = {},
        active = nil,
        suppress_pause_report = false,
        report = {
            running = nil,
            queue = {},
            progress = nil,
            pending_stops = {},
        },
    },
}

local load_current_layer
local start_quick_connect
local open_item

local function copy_table(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function set_from_list(values)
    local result = {}
    for _, value in ipairs(values or {}) do result[value] = true end
    return result
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function defer(callback)
    mp.add_timeout(0, callback)
end

local function url_encode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
end

local function with_query(path, parameters)
    local keys = {}
    for key, value in pairs(parameters or {}) do
        if value ~= nil then keys[#keys + 1] = key end
    end
    table.sort(keys)

    local query = {}
    for _, key in ipairs(keys) do
        query[#query + 1] = url_encode(key) .. "=" .. url_encode(parameters[key])
    end
    if #query == 0 then return path end
    return path .. (path:find("?", 1, true) and "&" or "?") .. table.concat(query, "&")
end

local function api_url(path)
    if tostring(path):match("^https?://") then return path end
    return options.url .. path
end

local function user_items_path(parameters)
    return with_query("/Users/" .. state.auth.user_id .. "/Items", parameters)
end

local function auth_path()
    return mp.command_native({ "expand-path", "~~state/jellyfin_auth.json" })
end

local function mkdir(path)
    if not path or path == "" then return end
    local args
    if package.config:sub(1, 1) == "\\" then
        args = { "cmd", "/d", "/c", "mkdir", path }
    else
        args = { "mkdir", "-p", path }
    end
    mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    })
end

local random_seeded = false

local function seed_random()
    if random_seeded then return end
    local pid = tonumber(utils.getpid and utils.getpid()) or 0
    math.randomseed(os.time() + pid + math.floor(mp.get_time() * 1000000))
    math.random(); math.random(); math.random()
    random_seeded = true
end

local function random_hex(length)
    seed_random()
    local result = {}
    for index = 1, length do
        result[index] = string.format("%x", math.random(0, 15))
    end
    return table.concat(result)
end

local function new_uuid()
    return table.concat({
        random_hex(8),
        random_hex(4),
        "4" .. random_hex(3),
        string.format("%x", math.random(8, 11)) .. random_hex(3),
        random_hex(12),
    }, "-")
end

local function save_auth()
    local content, json_error = utils.format_json({
        version = AUTH_VERSION,
        device_id = state.auth.device_id,
        server_url = options.url,
        user_id = state.auth.user_id,
        access_token = state.auth.access_token,
    })
    if not content then
        msg.error("无法序列化 Jellyfin 认证数据：" .. tostring(json_error))
        return false
    end

    local file = io.open(auth_path(), "w")
    if not file then
        msg.error("无法写入 Jellyfin 认证文件。")
        return false
    end
    file:write(content)
    file:close()
    return true
end

local function load_auth()
    local saved
    local file = io.open(auth_path(), "r")
    if file then
        local content = file:read("*all")
        file:close()
        saved = utils.parse_json(content)
    end

    if type(saved) == "table" and saved.version == AUTH_VERSION and
        type(saved.device_id) == "string" and saved.device_id ~= "" then
        state.auth.device_id = saved.device_id
        if saved.server_url == options.url then
            state.auth.user_id = tostring(saved.user_id or "")
            state.auth.access_token = tostring(saved.access_token or "")
        end
        return
    end

    state.auth.device_id = new_uuid()
    state.auth.user_id = ""
    state.auth.access_token = ""
    save_auth()
end

local function clear_credentials()
    state.auth.user_id = ""
    state.auth.access_token = ""
    save_auth()
end

local function quote_header_value(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function auth_part(name, value)
    return name .. '="' .. quote_header_value(value) .. '"'
end

local function authorization_header(include_token)
    local parts = {
        auth_part("Client", CLIENT_NAME),
        auth_part("Device", DEVICE_NAME),
        auth_part("DeviceId", state.auth.device_id),
        auth_part("Version", CLIENT_VERSION),
    }
    if include_token and state.auth.access_token ~= "" then
        table.insert(parts, 1, auth_part("Token", state.auth.access_token))
    end
    return "Authorization: MediaBrowser " .. table.concat(parts, ", ")
end

local function playback_authorization_header()
    if state.auth.access_token == "" then return nil end
    return "Authorization: MediaBrowser " .. auth_part("Token", state.auth.access_token)
end

local function build_curl_args(method, url, request_options)
    request_options = request_options or {}
    local args = {
        "curl", "-sS", "-m", tostring(request_options.timeout or REQUEST_TIMEOUT),
    }
    if method then
        args[#args + 1] = "-X"
        args[#args + 1] = method
    end
    for _, header in ipairs(request_options.headers or {}) do
        args[#args + 1] = "-H"
        args[#args + 1] = header
    end
    if request_options.body ~= nil then
        args[#args + 1] = "-d"
        args[#args + 1] = request_options.body
    end
    for _, argument in ipairs(request_options.extra_args or {}) do
        args[#args + 1] = argument
    end
    args[#args + 1] = url
    return args
end

local function powershell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function run_subprocess(args, stdin_data)
    local command = {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }
    if stdin_data ~= nil then command.stdin_data = stdin_data end
    local success, result = pcall(mp.command_native, command)
    return success and result or nil
end

local function copy_to_clipboard(value)
    value = tostring(value or "")
    local commands
    if package.config:sub(1, 1) == "\\" then
        commands = {
            { args = {
                "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                "Set-Clipboard -Value " .. powershell_quote(value),
            } },
        }
    elseif jit and jit.os == "OSX" then
        commands = { { args = { "pbcopy" }, stdin_data = value } }
    else
        commands = {
            { args = { "wl-copy" }, stdin_data = value },
            { args = { "xclip", "-selection", "clipboard" }, stdin_data = value },
            { args = { "xsel", "--clipboard", "--input" }, stdin_data = value },
        }
    end
    for _, command in ipairs(commands) do
        local result = run_subprocess(command.args, command.stdin_data)
        if result and result.status == 0 then return true end
    end
    return false
end

local function parse_http_result(success, result, error_message)
    local info = {
        ok = false,
        status = nil,
        curl_status = result and result.status or nil,
        error = error_message,
    }
    if not success or not result or result.status ~= 0 then return nil, info end

    local body, code = tostring(result.stdout or ""):match("^(.*)\n(%d%d%d)$")
    if not body then return nil, info end
    info.status = tonumber(code)
    if info.status < 200 or info.status >= 300 then return nil, info end

    info.ok = true
    if body == "" then return nil, info end
    local value, json_error = utils.parse_json(body)
    if value == nil then
        info.ok = false
        info.error = json_error or "invalid JSON"
    end
    return value, info
end

local function track_request(tracker, request_id)
    if request_id then tracker[#tracker + 1] = request_id end
end

local function untrack_request(tracker, request_id)
    for index, value in ipairs(tracker) do
        if value == request_id then
            table.remove(tracker, index)
            return
        end
    end
end

local function abort_requests(tracker)
    for _, request_id in ipairs(tracker) do
        mp.abort_async_command(request_id)
    end
    for index = #tracker, 1, -1 do tracker[index] = nil end
end

local function api_request_args(method, path, request_options)
    request_options = request_options or {}
    local headers = copy_table(request_options.headers)
    if request_options.auth ~= false then headers[#headers + 1] = authorization_header(true) end

    local body = request_options.body
    if type(body) == "table" then
        local json, json_error = utils.format_json(body)
        if not json then return nil, json_error or "invalid request JSON" end
        body = json
        headers[#headers + 1] = "Content-Type: application/json"
    end

    return build_curl_args(method, api_url(path), {
        timeout = request_options.timeout,
        headers = headers,
        body = body,
        extra_args = { "-w", "\n%{http_code}" },
    })
end

local function request_json(method, path, request_options, tracker, callback)
    local args, request_error = api_request_args(method, path, request_options)
    if not args then
        defer(function() callback(nil, { ok = false, error = request_error }) end)
        return nil
    end
    local request_id
    request_id = mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, error_message)
        if tracker then untrack_request(tracker, request_id) end
        local value, info = parse_http_result(success, result, error_message)
        callback(value, info)
    end)
    if tracker then track_request(tracker, request_id) end
    return request_id
end

local function request_sync(method, path, request_options)
    local args = api_request_args(method, path, request_options)
    if not args then return nil end
    return mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    })
end

local function is_auth_error(info)
    return info and info.status == 401
end

local function normalize_item(item)
    if type(item) ~= "table" or not item.Id then return nil end
    item.Name = tostring(item.Name or "")
    item.UserData = type(item.UserData) == "table" and item.UserData or {}
    if folder_types[item.Type] then item.IsFolder = true end
    if video_types[item.Type] or audio_types[item.Type] or photo_types[item.Type] or
        item.Type == "LiveTvChannel" then
        item.IsFolder = false
    end
    return item
end

local function media_kind(item)
    if not item or item.IsFolder == true or unsupported_leaf_types[item.Type] then return nil end
    if item.Type == "LiveTvChannel" then return "live" end
    if photo_types[item.Type] or item.MediaType == "Photo" then return "photo" end
    if audio_types[item.Type] or item.MediaType == "Audio" then return "audio" end
    if video_types[item.Type] or item.MediaType == "Video" then return "video" end
    return nil
end

local function is_allowed_item(item)
    return item and (item.IsFolder == true or folder_types[item.Type] or media_kind(item) ~= nil)
end

local function is_playable(item)
    return media_kind(item) ~= nil
end

local function is_live_view(view)
    local collection_type = tostring(view and view.CollectionType or ""):lower()
    return collection_type == "livetv" or collection_type == "live_tv"
end

local function is_played(item)
    return item.UserData.Played == true
end

local function is_partially_played(item)
    if item.IsFolder then
        local total = tonumber(item.RecursiveItemCount) or tonumber(item.ChildCount) or 0
        local unplayed = tonumber(item.UserData.UnplayedItemCount) or 0
        return total > 0 and unplayed > 0 and unplayed < total
    end
    return (tonumber(item.UserData.PlaybackPositionTicks) or 0) > 0 and not is_played(item)
end

local function watch_prefix(item)
    if is_played(item) then return "✅ " end
    if is_partially_played(item) then return "🔄 " end
    return "🔲 "
end

local function item_title(item)
    local name = item.Name
    if item.SeriesName then
        local season = item.ParentIndexNumber and string.format("S%02d", item.ParentIndexNumber) or ""
        local episode = item.IndexNumber and string.format("E%02d", item.IndexNumber) or ""
        local index = season .. episode
        if index ~= "" then return item.SeriesName .. " - " .. index .. " - " .. name end
        return item.SeriesName .. " - " .. name
    end
    return name
end

local function item_label(item)
    if item.Type == "LiveTvChannel" then
        local current = item.CurrentProgram
        if type(current) == "table" and current.Name and current.Name ~= "" then
            return item.Name .. " · " .. current.Name
        end
        return item.Name
    end
    local index = ""
    if item.IsFolder == false and item.IndexNumber then
        if item.ParentIndexNumber then
            index = string.format("S%02dE%02d · ", item.ParentIndexNumber, item.IndexNumber)
        else
            index = tostring(item.IndexNumber) .. " · "
        end
    end
    return watch_prefix(item) .. index .. item.Name
end

local function item_entry(item)
    return { kind = "item", item = item, label = item_label(item) }
end

local function route_entry(label, layer)
    return { kind = "route", label = label, layer = layer }
end

local function current_layer()
    return state.layers[#state.layers]
end

local function cancel_menu_requests()
    state.menu_generation = state.menu_generation + 1
    abort_requests(state.menu_requests)
end

local function invalidate_select(terminate)
    state.select_session = state.select_session + 1
    if terminate then input.terminate() end
end

local function cancel_quick_connect(terminate)
    state.quick.generation = state.quick.generation + 1
    state.quick.active = false
    state.quick.polling = false
    state.quick.secret = ""
    if state.quick.timer then
        state.quick.timer:kill()
        state.quick.timer = nil
    end
    abort_requests(state.quick.requests)
    if terminate then invalidate_select(true) end
end

local function close_menu(terminate)
    state.shown = false
    cancel_menu_requests()
    if state.quick.active then cancel_quick_connect(false) end
    invalidate_select(terminate ~= false)
    mp.osd_message("", 0)
end

local function reconnect()
    cancel_menu_requests()
    clear_credentials()
    state.shown = true
    start_quick_connect()
end

local function show_request_error(info)
    if is_auth_error(info) then
        reconnect()
        return
    end
    state.shown = false
    if info and info.status == 403 then
        mp.osd_message("当前用户无权访问此内容。", 5)
    elseif info and info.status == 503 then
        mp.osd_message("Jellyfin 正在启动或暂时不可用。", 5)
    elseif info and info.status and info.status >= 500 then
        mp.osd_message("Jellyfin 服务器错误。", 5)
    elseif info and info.status then
        mp.osd_message("Jellyfin 请求失败（HTTP " .. tostring(info.status) .. "）。", 5)
    else
        mp.osd_message("无法连接 Jellyfin，请检查地址和网络。", 5)
    end
end

local function show_entries(entries)
    state.entries = entries or {}
    local layer = current_layer()
    local labels = {}
    local actions = {}
    local offset = #state.layers > 1 and 1 or 0

    if offset == 1 then
        labels[1] = "‹ 返回"
        actions[1] = { kind = "back" }
    end
    for index, entry in ipairs(state.entries) do
        labels[index + offset] = entry.label
        actions[index + offset] = entry
    end

    if #labels == 0 then
        state.shown = false
        mp.osd_message("没有可显示的媒体内容。", 4)
        return
    end

    local default_item = clamp((tonumber(layer.selection) or 1) + offset, 1, #labels)
    invalidate_select(false)
    local session = state.select_session
    local pending_entry
    mp.osd_message("", 0)

    input.select({
        prompt = layer.title or "Jellyfin",
        items = labels,
        default_item = default_item,
        submit = function(index)
            index = tonumber(index)
            local entry = index and actions[index]
            if not entry then return end
            pending_entry = entry
            if entry.kind ~= "back" then layer.selection = index - offset end
        end,
        closed = function()
            if session ~= state.select_session then return end
            if not pending_entry then
                close_menu(false)
                return
            end
            defer(function()
                if session ~= state.select_session then return end
                state.shown = true
                local entry = pending_entry
                if entry.kind == "back" then
                    table.remove(state.layers)
                    load_current_layer()
                elseif entry.kind == "page" then
                    layer.page = math.max(0, (layer.page or 0) + entry.delta)
                    layer.selection = 1
                    load_current_layer()
                elseif entry.kind == "route" then
                    state.layers[#state.layers + 1] = entry.layer
                    load_current_layer()
                else
                    open_item(entry.item)
                end
            end)
        end,
    })
end

local function sort_episode_display(items)
    local original = {}
    for index, item in ipairs(items) do original[item] = index end
    table.sort(items, function(left, right)
        local left_played = is_played(left)
        local right_played = is_played(right)
        if left_played ~= right_played then return not left_played end
        if not left_played then
            local left_date = tostring(left.DateCreated or "")
            local right_date = tostring(right.DateCreated or "")
            if left_date ~= right_date then return left_date > right_date end
        end
        local left_season = tonumber(left.ParentIndexNumber) or 0
        local right_season = tonumber(right.ParentIndexNumber) or 0
        if left_season ~= right_season then return left_season > right_season end
        local left_episode = tonumber(left.IndexNumber) or 0
        local right_episode = tonumber(right.IndexNumber) or 0
        if left_episode ~= right_episode then return left_episode > right_episode end
        return original[left] < original[right]
    end)
end

local function view_layer(view)
    local collection_type = tostring(view.CollectionType or ""):lower()
    if is_live_view(view) then
        return {
            kind = "live_channels",
            title = view.Name,
            page = 0,
            selection = 1,
        }
    end

    local include_types
    local recursive
    local sort_by = "DateCreated"
    local sort_order = "Descending"
    if collection_type == "movies" then
        include_types = "Movie,BoxSet"
        recursive = true
    elseif collection_type == "tvshows" or collection_type == "tvs" then
        include_types = "Series"
        recursive = true
    else
        include_types = all_include_types
        recursive = false
        if collection_type == "music" or collection_type == "musicvideos" or
            collection_type == "photos" or collection_type == "playlists" then
            sort_by = "SortName"
            sort_order = "Ascending"
        end
    end
    return {
        kind = "items",
        title = view.Name,
        parent_id = view.Id,
        include_types = include_types,
        recursive = recursive,
        sort_by = sort_by,
        sort_order = sort_order,
        page = 0,
        selection = 1,
    }
end

local function folder_layer(item)
    if item.Type == "Series" then
        return {
            kind = "episodes",
            title = item.Name,
            parent_id = item.Id,
            include_types = "Episode",
            recursive = true,
            sort_by = "ParentIndexNumber,IndexNumber",
            sort_order = "Ascending",
            selection = 1,
        }
    end
    if item.Type == "MusicAlbum" then
        return {
            kind = "items",
            title = item.Name,
            parent_id = item.Id,
            include_types = "Audio",
            recursive = false,
            sort_by = "ParentIndexNumber,IndexNumber,SortName",
            sort_order = "Ascending",
            page = 0,
            selection = 1,
        }
    end
    if item.Type == "Playlist" then
        return {
            kind = "playlist",
            title = item.Name,
            playlist_id = item.Id,
            page = 0,
            selection = 1,
        }
    end
    return {
        kind = "items",
        title = item.Name,
        parent_id = item.Id,
        include_types = all_include_types,
        recursive = false,
        sort_by = "SortName",
        sort_order = "Ascending",
        page = 0,
        selection = 1,
    }
end

local function root_latest_item(view, raw_item)
    local item = normalize_item(raw_item)
    if not item then return nil end
    local series_id
    local collection_type = tostring(view.CollectionType or ""):lower()
    if (collection_type == "tvshows" or collection_type == "tvs") and
        item.Type == "Episode" and item.SeriesId then
        series_id = item.SeriesId
        item = normalize_item({
            Id = series_id,
            Name = item.SeriesName ~= "" and item.SeriesName or item.Name,
            Type = "Series",
            IsFolder = true,
        })
    end
    if not is_allowed_item(item) then return nil end
    return item, series_id
end

local function load_root(generation)
    local user_result, views_result
    local pending = 2

    local function base_done()
        pending = pending - 1
        if pending > 0 or generation ~= state.menu_generation or not state.shown then return end
        if not user_result.value then show_request_error(user_result.info); return end
        if not views_result.value or type(views_result.value.Items) ~= "table" then
            show_request_error(views_result.info)
            return
        end

        local configuration = user_result.value.Configuration or {}
        local excludes = set_from_list(configuration.MyMediaExcludes)
        for id in pairs(set_from_list(configuration.LatestItemsExcludes)) do excludes[id] = true end
        local visible_views = {}
        local other_entries = {}

        for _, raw_view in ipairs(views_result.value.Items) do
            local view = normalize_item(raw_view)
            if view then
                local route = route_entry("媒体库 · " .. view.Name, view_layer(view))
                if excludes[view.Id] then
                    other_entries[#other_entries + 1] = route
                else
                    visible_views[#visible_views + 1] = {
                        view = view,
                        route = route,
                        latest = {},
                    }
                end
            end
        end

        local latest_pending = 0
        local latest_series_ids = {}
        local series_by_id = {}
        local series_resolved = false
        local function finish_root()
            if latest_pending > 0 or generation ~= state.menu_generation or not state.shown then return end
            if not series_resolved then
                series_resolved = true
                local ids = {}
                for id in pairs(latest_series_ids) do ids[#ids + 1] = id end
                table.sort(ids)
                if #ids > 0 then
                    latest_pending = 1
                    request_json("GET", user_items_path({
                        Ids = table.concat(ids, ","),
                        Fields = "RecursiveItemCount,ChildCount",
                        EnableImages = false,
                        EnableUserData = true,
                    }), nil, state.menu_requests, function(value, info)
                        if generation ~= state.menu_generation or not state.shown then return end
                        if is_auth_error(info) then reconnect(); return end
                        if value and type(value.Items) == "table" then
                            for _, raw_item in ipairs(value.Items) do
                                local item = normalize_item(raw_item)
                                if item and item.Type == "Series" then series_by_id[item.Id] = item end
                            end
                        else
                            msg.warn("读取首页系列信息失败。")
                        end
                        latest_pending = 0
                        finish_root()
                    end)
                    return
                end
            end
            local entries = {}
            for _, group in ipairs(visible_views) do
                entries[#entries + 1] = group.route
                for _, candidate in ipairs(group.latest) do
                    entries[#entries + 1] = item_entry(
                        candidate.series_id and series_by_id[candidate.series_id] or candidate.item)
                end
            end
            if #other_entries > 0 then
                entries[#entries + 1] = route_entry("其他", {
                    kind = "static",
                    title = "其他",
                    entries = other_entries,
                    selection = 1,
                })
            end
            show_entries(entries)
        end

        for _, group in ipairs(visible_views) do
            if not is_live_view(group.view) then
                latest_pending = latest_pending + 1
                local path = with_query("/Users/" .. state.auth.user_id .. "/Items/Latest", {
                    ParentId = group.view.Id,
                    Limit = options.home_latest_limit,
                    Fields = "RecursiveItemCount,ChildCount",
                    EnableImages = false,
                    EnableUserData = true,
                })
                request_json("GET", path, nil, state.menu_requests, function(value, info)
                    if generation ~= state.menu_generation or not state.shown then return end
                    if is_auth_error(info) then reconnect(); return end
                    if value then
                        local values = value.Items or value
                        local seen = {}
                        for _, raw_item in ipairs(type(values) == "table" and values or {}) do
                            local item, series_id = root_latest_item(group.view, raw_item)
                            if item and not seen[item.Id] then
                                seen[item.Id] = true
                                group.latest[#group.latest + 1] = {
                                    item = item,
                                    series_id = series_id,
                                }
                                if series_id then latest_series_ids[series_id] = true end
                            end
                        end
                    else
                        msg.warn("读取“" .. group.view.Name .. "”的最新内容失败。")
                    end
                    latest_pending = latest_pending - 1
                    finish_root()
                end)
            end
        end
        finish_root()
    end

    request_json("GET", "/Users/" .. state.auth.user_id, nil, state.menu_requests, function(value, info)
        if generation ~= state.menu_generation then return end
        if is_auth_error(info) then reconnect(); return end
        user_result = { value = value, info = info }
        base_done()
    end)
    request_json("GET", "/Users/" .. state.auth.user_id .. "/Views", nil, state.menu_requests, function(value, info)
        if generation ~= state.menu_generation then return end
        if is_auth_error(info) then reconnect(); return end
        views_result = { value = value, info = info }
        base_done()
    end)
end

local function load_items(layer, generation)
    local parameters = {
        ParentId = layer.parent_id,
        IncludeItemTypes = layer.include_types,
        Recursive = layer.recursive and "true" or "false",
        SortBy = layer.sort_by,
        SortOrder = layer.sort_order,
        Fields = "RecursiveItemCount,ChildCount",
        EnableImages = false,
        EnableUserData = true,
        EnableTotalRecordCount = true,
    }
    if layer.kind == "search" then
        parameters.ParentId = nil
        parameters.SearchTerm = layer.query
        parameters.SortBy = nil
        parameters.SortOrder = nil
    end
    if layer.kind ~= "episodes" then
        parameters.StartIndex = (layer.page or 0) * options.page_size
        parameters.Limit = options.page_size
    end

    request_json("GET", user_items_path(parameters), nil, state.menu_requests, function(value, info)
        if generation ~= state.menu_generation or not state.shown then return end
        if not value or type(value.Items) ~= "table" then show_request_error(info); return end

        local items = {}
        for _, raw_item in ipairs(value.Items) do
            local item = normalize_item(raw_item)
            if item and is_allowed_item(item) then items[#items + 1] = item end
        end
        if layer.kind == "episodes" then
            sort_episode_display(items)
            layer.all_items = items
        end

        local entries = {}
        if layer.kind ~= "episodes" and (layer.page or 0) > 0 then
            entries[#entries + 1] = { kind = "page", label = "‹ 上一页", delta = -1 }
        end
        for _, item in ipairs(items) do entries[#entries + 1] = item_entry(item) end
        if layer.kind ~= "episodes" then
            local start_index = tonumber(value.StartIndex) or ((layer.page or 0) * options.page_size)
            local total = tonumber(value.TotalRecordCount) or (start_index + #items)
            if start_index + #value.Items < total then
                entries[#entries + 1] = { kind = "page", label = "下一页 ›", delta = 1 }
            end
        end
        show_entries(entries)
    end)
end

local function load_playlist(layer, generation)
    local start_index = (layer.page or 0) * options.page_size
    local path = with_query("/Playlists/" .. layer.playlist_id .. "/Items", {
        UserId = state.auth.user_id,
        StartIndex = start_index,
        Limit = options.page_size,
        Fields = "RecursiveItemCount,ChildCount",
        EnableImages = "false",
        EnableUserData = "true",
    })
    request_json("GET", path, nil, state.menu_requests, function(value, info)
        if generation ~= state.menu_generation or not state.shown then return end
        if not value or type(value.Items) ~= "table" then show_request_error(info); return end

        local entries = {}
        if (layer.page or 0) > 0 then
            entries[#entries + 1] = { kind = "page", label = "‹ 上一页", delta = -1 }
        end
        for _, raw_item in ipairs(value.Items) do
            local item = normalize_item(raw_item)
            if item and is_allowed_item(item) then entries[#entries + 1] = item_entry(item) end
        end
        local total = tonumber(value.TotalRecordCount) or (start_index + #value.Items)
        if start_index + #value.Items < total then
            entries[#entries + 1] = { kind = "page", label = "下一页 ›", delta = 1 }
        end
        show_entries(entries)
    end)
end

local function load_live_channels(layer, generation)
    local start_index = (layer.page or 0) * options.page_size
    local path = with_query("/LiveTv/Channels", {
        UserId = state.auth.user_id,
        StartIndex = start_index,
        Limit = options.page_size,
        AddCurrentProgram = "true",
        EnableImages = "false",
        EnableUserData = "true",
    })
    request_json("GET", path, nil, state.menu_requests, function(value, info)
        if generation ~= state.menu_generation or not state.shown then return end
        if not value or type(value.Items) ~= "table" then show_request_error(info); return end

        local entries = {}
        if (layer.page or 0) > 0 then
            entries[#entries + 1] = { kind = "page", label = "‹ 上一页", delta = -1 }
        end
        for _, raw_item in ipairs(value.Items) do
            local item = normalize_item(raw_item)
            if item then
                item.Type = "LiveTvChannel"
                item.IsFolder = false
                entries[#entries + 1] = item_entry(item)
            end
        end
        local total = tonumber(value.TotalRecordCount) or (start_index + #value.Items)
        if start_index + #value.Items < total then
            entries[#entries + 1] = { kind = "page", label = "下一页 ›", delta = 1 }
        end
        show_entries(entries)
    end)
end

load_current_layer = function()
    cancel_menu_requests()
    local generation = state.menu_generation
    local layer = current_layer()
    mp.osd_message("正在加载…", REQUEST_TIMEOUT + 1)
    if layer.kind == "root" then
        load_root(generation)
    elseif layer.kind == "static" then
        show_entries(layer.entries)
    elseif layer.kind == "live_channels" then
        load_live_channels(layer, generation)
    elseif layer.kind == "playlist" then
        load_playlist(layer, generation)
    else
        load_items(layer, generation)
    end
end

local function report_path(kind)
    if kind == "started" then return "/Sessions/Playing" end
    if kind == "progress" then return "/Sessions/Playing/Progress" end
    return "/Sessions/Playing/Stopped"
end

local function build_report_body(session, kind, failed)
    local body = {
        ItemId = session.entry.item.Id,
        PlaySessionId = session.entry.session_id,
        PositionTicks = session.entry.kind == "live" and 0 or
            math.floor(math.max(0, session.position_ticks or 0)),
    }
    if session.entry.media_source_id then body.MediaSourceId = session.entry.media_source_id end
    if session.entry.live_stream_id then body.LiveStreamId = session.entry.live_stream_id end
    if kind ~= "stopped" then
        body.CanSeek = session.entry.kind ~= "live"
        body.IsPaused = session.is_paused == true
        body.IsMuted = session.is_muted == true
        body.PlayMethod = "DirectPlay"
    else
        body.Failed = failed == true
    end
    return body
end

local function pump_reports()
    local report = state.playback.report
    if report.running then return end

    local event
    if #report.queue > 0 then
        event = table.remove(report.queue, 1)
    elseif report.progress then
        event = report.progress
        report.progress = nil
    else
        return
    end

    local request_id
    request_id = request_json("POST", report_path(event.kind), {
        body = event.body,
    }, nil, function(_, info)
        if report.running and report.running.id == request_id then report.running = nil end
        local failed = not (info and info.ok)
        local status = info and info.status
        if failed then
            msg.debug("Jellyfin 播放状态上报失败：" .. event.kind)
            if status == 401 then clear_credentials() end
        elseif event.kind == "stopped" then
            for index, pending in ipairs(report.pending_stops) do
                if pending.session == event.session then
                    table.remove(report.pending_stops, index)
                    break
                end
            end
        end
        if event.done then event.done(not failed) end
        pump_reports()
    end)
    report.running = { id = request_id, event = event }
end

local function enqueue_report(kind, session, failed, done)
    if state.auth.access_token == "" or not session then
        if done then defer(function() done(false) end) end
        return
    end
    local event = {
        kind = kind,
        session = session,
        body = build_report_body(session, kind, failed),
        done = done,
    }
    local report = state.playback.report
    if kind == "progress" then
        report.progress = event
    else
        if kind == "stopped" and report.progress and report.progress.session == session then
            report.progress = nil
        end
        if kind == "stopped" then
            report.pending_stops[#report.pending_stops + 1] = {
                session = session,
                failed = failed == true,
            }
        end
        report.queue[#report.queue + 1] = event
    end
    pump_reports()
end

local function cancel_reports()
    local report = state.playback.report
    if report.running and report.running.id then mp.abort_async_command(report.running.id) end
    report.running = nil
    report.queue = {}
    report.progress = nil
end

local function post_stopped_sync(session, failed)
    if state.auth.access_token == "" or not session then return end
    request_sync("POST", report_path("stopped"), {
        timeout = 3,
        body = build_report_body(session, "stopped", failed),
    })
end

local function flush_stops_sync(extra_session, extra_failed)
    local report = state.playback.report
    cancel_reports()
    local stops = report.pending_stops
    report.pending_stops = {}
    local extra_present = false
    for _, pending in ipairs(stops) do
        if pending.session == extra_session then extra_present = true end
        post_stopped_sync(pending.session, pending.failed)
    end
    if extra_session and not extra_present then post_stopped_sync(extra_session, extra_failed) end
end

local function mark_live_closed(entry)
    entry.live_close_state = "closed"
    entry.live_close_request = nil
    state.playback.live[entry.session_id] = nil
end

local function close_live_stream(entry, synchronous)
    if not entry or not entry.live_stream_id or entry.live_close_state == "closed" then return end
    entry.live_close_state = entry.live_close_state or "open"
    state.playback.live[entry.session_id] = entry
    local path = with_query("/LiveStreams/Close", { liveStreamId = entry.live_stream_id })
    if synchronous then
        if entry.live_close_request then
            mp.abort_async_command(entry.live_close_request)
            entry.live_close_request = nil
        end
        mark_live_closed(entry)
        request_sync("POST", path, {
            timeout = 3,
            headers = { "Content-Length: 0" },
        })
        return
    end
    if entry.live_close_state == "closing" then return end
    entry.live_close_state = "closing"
    local request_id
    request_id = request_json("POST", path, {
        headers = { "Content-Length: 0" },
    }, nil, function(_, info)
        if entry.live_close_request == request_id then entry.live_close_request = nil end
        if info and info.ok then
            mark_live_closed(entry)
        elseif entry.live_close_state ~= "closed" then
            entry.live_close_state = "open"
            state.playback.live[entry.session_id] = entry
            msg.debug("关闭 Jellyfin 直播流失败。")
        end
    end)
    entry.live_close_request = request_id
end

local function close_all_live_streams_sync()
    local entries = {}
    for _, entry in pairs(state.playback.live) do entries[#entries + 1] = entry end
    for _, entry in ipairs(entries) do close_live_stream(entry, true) end
end

local function snapshot_session(session, prefer_duration)
    if not session then return end
    if session.entry.kind == "live" then
        session.position_ticks = 0
        session.is_paused = mp.get_property_bool("pause") == true
        session.is_muted = mp.get_property_bool("mute") == true
        return
    end
    local time_position = mp.get_property_number("time-pos")
    local duration = mp.get_property_number("duration")
    if duration and duration >= 0 then session.duration_ticks = math.floor(duration * TICKS_PER_SECOND) end
    if prefer_duration and session.duration_ticks then
        session.position_ticks = session.duration_ticks
    elseif time_position and time_position >= 0 then
        session.position_ticks = math.floor(time_position * TICKS_PER_SECOND)
    end
    session.is_paused = mp.get_property_bool("pause") == true
    session.is_muted = mp.get_property_bool("mute") == true
end

local function safe_filename_part(value)
    local result = tostring(value or ""):gsub("[^%w%-_%.]", "_")
    return result ~= "" and result or "unknown"
end

local subtitle_directory = utils.join_path(options.cache_path, "subtitles")

local function abort_subtitles(session)
    for _, request_id in ipairs(session and session.subtitle_requests or {}) do
        mp.abort_async_command(request_id)
    end
    if session then session.subtitle_requests = {} end
end

local function media_source(item, preferred_id, require_streams)
    if type(item) ~= "table" or type(item.MediaSources) ~= "table" then return nil end
    local function usable(source)
        if type(source) ~= "table" or not source.Id then return false end
        if source.MediaStreams == nil then source.MediaStreams = item.MediaStreams end
        return not require_streams or type(source.MediaStreams) == "table"
    end
    if preferred_id and preferred_id ~= "" then
        for _, source in ipairs(item.MediaSources) do
            if source.Id == preferred_id and usable(source) then return source end
        end
    end
    for _, source in ipairs(item.MediaSources) do
        if usable(source) then return source end
    end
    return nil
end

local function download_subtitle(session, source, stream)
    if not source.Id or stream.Index == nil then return end
    local extension = tostring((stream.Path and stream.Path:match("%.([^.]+)$")) or stream.Codec or "srt")
        :lower():gsub("[^%w]", "")
    if extension == "" then extension = "srt" end
    local filename = table.concat({
        safe_filename_part(session.entry.item.Id),
        safe_filename_part(source.Id),
        safe_filename_part(stream.Index),
    }, "_") .. "." .. extension
    local filepath = utils.join_path(subtitle_directory, filename)
    local path = "/Videos/" .. session.entry.item.Id .. "/" .. source.Id ..
        "/Subtitles/" .. tostring(stream.Index) .. "/Stream." .. extension

    local request_id
    request_id = mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = build_curl_args(nil, api_url(path), {
            timeout = SUBTITLE_TIMEOUT,
            headers = { authorization_header(true) },
            extra_args = { "-f", "-o", filepath },
        }),
    }, function(success, result)
        untrack_request(session.subtitle_requests, request_id)
        if state.playback.active ~= session then return end
        if success and result and result.status == 0 then
            mp.commandv("sub-add", filepath, "auto", stream.DisplayTitle or "", stream.Language or "")
        else
            msg.warn("下载 Jellyfin 字幕失败：" .. tostring(stream.DisplayTitle or stream.Index))
        end
    end)
    session.subtitle_requests[#session.subtitle_requests + 1] = request_id
end

local function load_external_subtitles(session)
    local path = user_items_path({
        Ids = session.entry.item.Id,
        Fields = "MediaSources,MediaStreams",
        Limit = 1,
        EnableImages = false,
        EnableUserData = false,
    })
    local request_id
    request_id = request_json("GET", path, nil, session.subtitle_requests, function(value, info)
        if state.playback.active ~= session then return end
        if is_auth_error(info) then clear_credentials(); return end
        local item = value and value.Items and value.Items[1]
        local sources = item and item.MediaSources
        if type(sources) ~= "table" then return end

        local source = media_source(item, session.entry.media_source_id, true)
        if not source then return end
        for _, stream in ipairs(source.MediaStreams) do
            if stream.IsTextSubtitleStream == true and stream.IsExternal == true then
                download_subtitle(session, source, stream)
            end
        end
    end)
    return request_id
end

local function stream_url(entry)
    if entry.kind == "photo" then
        return api_url("/Items/" .. entry.item.Id .. "/Images/Primary")
    end
    local prefix = entry.kind == "audio" and "/Audio/" or "/Videos/"
    if entry.kind == "live" then
        return api_url(with_query(prefix .. entry.item.Id .. "/stream", {
            static = "true",
            DeviceId = state.auth.device_id,
            PlaySessionId = entry.session_id,
            MediaSourceId = entry.media_source_id,
            LiveStreamId = entry.live_stream_id,
        }))
    end
    local url = api_url(prefix .. entry.item.Id .. "/stream?static=true")
    if not entry.media_source_id or entry.media_source_id == "" then return url end
    return url .. "&MediaSourceId=" .. url_encode(entry.media_source_id)
end

local function item_media_source_id(item)
    local source = media_source(item, item.MediaSourceId, false)
    return source and source.Id or item.MediaSourceId
end

local function resume_seconds(item)
    if item.UserData.Played == true then return nil end
    local ticks = tonumber(item.UserData.PlaybackPositionTicks) or 0
    if ticks <= 0 then return nil end
    return ticks / TICKS_PER_SECOND
end

local function playback_options(entry)
    local values = {
        ["force-media-title"] = entry.title,
        ["title"] = entry.title,
        ["osd-playing-msg"] = entry.title,
        ["osd-playlist-entry"] = "title",
    }
    local auth_header = playback_authorization_header()
    if auth_header then values["http-header-fields"] = auth_header end
    if entry.kind == "photo" then values["image-display-duration"] = "inf" end
    local start = (entry.kind == "video" or entry.kind == "audio") and resume_seconds(entry.item)
    if start then
        values.start = string.format("%.7f", start):gsub("0+$", ""):gsub("%.$", "")
    end
    return values
end

local function start_playlist(items)
    state.playback.planned = {}
    for _, wrapper in ipairs(items) do
        local entry = wrapper.entry or {
            item = wrapper.item,
            title = wrapper.title or item_title(wrapper.item),
        }
        entry.kind = entry.kind or media_kind(entry.item)
        entry.session_id = entry.session_id or (entry.kind ~= "photo" and new_uuid() or nil)
        entry.media_source_id = entry.media_source_id or item_media_source_id(entry.item)
        entry.url = stream_url(entry)
        if entry.session_id then state.playback.planned[entry.url] = entry end
        if entry.live_stream_id then
            entry.live_close_state = entry.live_close_state or "open"
            state.playback.live[entry.session_id] = entry
        end
        wrapper.entry = entry
    end

    mp.commandv("playlist-play-index", "none")
    mp.commandv("playlist-clear")
    for index, wrapper in ipairs(items) do
        local entry = wrapper.entry
        mp.command_native({
            "loadfile",
            entry.url,
            index == 1 and "replace" or "append",
            -1,
            playback_options(entry),
        })
    end
end

local function prepare_live_playback(item)
    local generation = state.preparing_generation
    mp.osd_message("正在打开直播频道…", REQUEST_TIMEOUT + 1)
    request_json("POST", "/Items/" .. item.Id .. "/PlaybackInfo", {
        body = {
            UserId = state.auth.user_id,
            StartTimeTicks = 0,
            IsPlayback = true,
            AutoOpenLiveStream = true,
            EnableDirectPlay = true,
            EnableDirectStream = true,
            EnableTranscoding = false,
            AllowVideoStreamCopy = true,
            AllowAudioStreamCopy = true,
        },
    }, state.preparing_requests, function(value, info)
        local opened_source
        for _, candidate in ipairs(value and value.MediaSources or {}) do
            if candidate.LiveStreamId then opened_source = candidate; break end
        end

        local opened = opened_source and {
            item = item,
            kind = "live",
            session_id = value.PlaySessionId or new_uuid(),
            live_stream_id = opened_source.LiveStreamId,
        }
        local source = opened_source and opened_source.Id and not opened_source.TranscodingUrl and
            (opened_source.SupportsDirectPlay ~= false or opened_source.SupportsDirectStream ~= false) and
            opened_source or nil
        if generation ~= state.preparing_generation then
            close_live_stream(opened, false)
            return
        end
        if is_auth_error(info) then reconnect(); return end
        if info and info.status == 403 then
            close_live_stream(opened, false)
            mp.osd_message("当前用户无权访问直播电视。", 5)
            return
        end
        if not source or not value.PlaySessionId then
            close_live_stream(opened, false)
            mp.osd_message("该直播频道没有可直连的媒体源。", 5)
            return
        end

        local entry = {
            item = item,
            title = item_title(item),
            kind = "live",
            session_id = value.PlaySessionId,
            media_source_id = source.Id,
            live_stream_id = source.LiveStreamId,
        }
        mp.osd_message("", 0)
        start_playlist({ { item = item, entry = entry } })
    end)
end

local function chronological_episode_queue(layer, selected)
    local items = {}
    for _, item in ipairs(layer.all_items or {}) do items[#items + 1] = item end
    local original = {}
    for index, item in ipairs(items) do original[item] = index end
    table.sort(items, function(left, right)
        local left_season = tonumber(left.ParentIndexNumber) or math.huge
        local right_season = tonumber(right.ParentIndexNumber) or math.huge
        if left_season ~= right_season then return left_season < right_season end
        local left_episode = tonumber(left.IndexNumber) or math.huge
        local right_episode = tonumber(right.IndexNumber) or math.huge
        if left_episode ~= right_episode then return left_episode < right_episode end
        return original[left] < original[right]
    end)

    local selected_index
    for index, item in ipairs(items) do
        if item.Id == selected.Id then selected_index = index; break end
    end
    if not selected_index then return { selected } end

    local result = {}
    for index = selected_index, #items do result[#result + 1] = items[index] end
    return result
end

local function part_wrappers(item, additional_parts)
    if #additional_parts == 0 then return { { item = item, title = item_title(item) } } end
    local base_title = item_title(item)
    local wrappers = {
        { item = item, title = base_title .. " (Part 1)" },
    }
    for index, part in ipairs(additional_parts) do
        local normalized = normalize_item(part)
        if normalized then
            wrappers[#wrappers + 1] = {
                item = normalized,
                title = base_title .. " (Part " .. tostring(index + 1) .. ")",
            }
        end
    end
    return wrappers
end

local function prepare_playback(selected)
    close_menu(true)
    state.preparing_generation = state.preparing_generation + 1
    abort_requests(state.preparing_requests)
    local generation = state.preparing_generation
    mp.osd_message("正在准备播放…", REQUEST_TIMEOUT + 1)

    if media_kind(selected) == "live" then
        prepare_live_playback(selected)
        return
    end

    local layer = current_layer()
    local base_items = layer.kind == "episodes" and chronological_episode_queue(layer, selected) or { selected }
    local expanded = {}
    local pending = 0
    local failed = false

    local function fail(message, info)
        if failed then return end
        failed = true
        state.preparing_generation = state.preparing_generation + 1
        abort_requests(state.preparing_requests)
        if is_auth_error(info) then reconnect() else mp.osd_message(message, 5) end
    end

    local function finish()
        if pending > 0 or failed or generation ~= state.preparing_generation then return end
        local wrappers = {}
        for index = 1, #base_items do
            for _, wrapper in ipairs(expanded[index]) do wrappers[#wrappers + 1] = wrapper end
        end
        mp.osd_message("", 0)
        start_playlist(wrappers)
    end

    for index, item in ipairs(base_items) do
        local part_count = tonumber(item.PartCount) or 1
        if media_kind(item) == "video" and part_count > 1 then
            pending = pending + 1
            local path = with_query("/Videos/" .. item.Id .. "/AdditionalParts", {
                userId = state.auth.user_id,
            })
            request_json("GET", path, nil, state.preparing_requests, function(value, info)
                if generation ~= state.preparing_generation then return end
                if not value or type(value.Items) ~= "table" or #value.Items == 0 then
                    fail("无法读取分段视频，播放已取消。", info)
                    return
                end
                expanded[index] = part_wrappers(item, value.Items)
                pending = pending - 1
                finish()
            end)
        else
            expanded[index] = { { item = item, title = item_title(item) } }
        end
    end
    finish()
end

open_item = function(item)
    if is_playable(item) then
        prepare_playback(item)
        return
    end
    if item.IsFolder then
        state.layers[#state.layers + 1] = folder_layer(item)
        load_current_layer()
    end
end

local function show_quick_connect(code, generation, status)
    invalidate_select(false)
    local session = state.select_session
    local submitted = false
    local submit_status = status
    input.select({
        prompt = "快速连接：在 Jellyfin 客户端中打开“设置 → 快速连接”",
        items = { "验证码: " .. code .. (status or "（点击复制）") },
        default_item = 1,
        submit = function()
            submitted = true
            submit_status = copy_to_clipboard(code) and
                "（已复制，等待授权）" or "（复制失败，请手动输入）"
        end,
        closed = function()
            if session ~= state.select_session or generation ~= state.quick.generation then return end
            if submitted and state.quick.active then
                defer(function()
                    if session ~= state.select_session or generation ~= state.quick.generation or
                        not state.quick.active then return end
                    show_quick_connect(code, generation, submit_status)
                end)
                return
            end
            cancel_quick_connect(false)
            state.shown = false
        end,
    })
end

local function finish_quick_connect(generation)
    local body = { Secret = state.quick.secret }
    request_json("POST", "/Users/AuthenticateWithQuickConnect", {
        auth = false,
        headers = { authorization_header(false) },
        body = body,
    }, state.quick.requests, function(value)
        if generation ~= state.quick.generation or not state.quick.active then return end
        if not value or not value.AccessToken or not value.User or not value.User.Id then
            cancel_quick_connect(true)
            state.shown = false
            mp.osd_message("快速连接已授权，但无法取得登录令牌。", 6)
            return
        end
        state.auth.user_id = value.User.Id
        state.auth.access_token = value.AccessToken
        save_auth()
        cancel_quick_connect(true)
        state.shown = true
        state.layers = { { kind = "root", title = "Jellyfin", selection = 1 } }
        defer(load_current_layer)
    end)
end

local function poll_quick_connect(generation)
    if generation ~= state.quick.generation or not state.quick.active or state.quick.polling then return end
    state.quick.polling = true
    local path = with_query("/QuickConnect/Connect", { secret = state.quick.secret })
    request_json("GET", path, { auth = false }, state.quick.requests, function(value, info)
        if generation ~= state.quick.generation or not state.quick.active then return end
        state.quick.polling = false
        if value and value.Authenticated == true then
            if state.quick.timer then state.quick.timer:kill(); state.quick.timer = nil end
            finish_quick_connect(generation)
        elseif info and info.status and info.status ~= 404 then
            msg.debug("快速连接轮询失败：HTTP " .. tostring(info.status))
        end
    end)
end

start_quick_connect = function()
    cancel_quick_connect(true)
    state.quick.generation = state.quick.generation + 1
    local generation = state.quick.generation
    state.quick.active = true
    state.shown = true
    mp.osd_message("正在启动 Jellyfin 快速连接…", REQUEST_TIMEOUT + 1)

    request_json("POST", "/QuickConnect/Initiate", {
        auth = false,
        headers = { authorization_header(false), "Content-Length: 0" },
    }, state.quick.requests, function(value)
        if generation ~= state.quick.generation or not state.quick.active then return end
        if not value or not value.Code or not value.Secret then
            cancel_quick_connect(true)
            state.shown = false
            mp.osd_message("Jellyfin 快速连接失败，请检查服务器地址。", 6)
            return
        end
        state.quick.secret = value.Secret
        mp.osd_message("", 0)
        show_quick_connect(tostring(value.Code), generation)
        state.quick.timer = mp.add_periodic_timer(3, function() poll_quick_connect(generation) end)
        poll_quick_connect(generation)
    end)
end

local function toggle_menu()
    if state.shown then
        close_menu(true)
        return
    end
    if options.url == "" then
        mp.osd_message("请先在 jellyfin_client.conf 中设置 Jellyfin 地址。", 6)
        return
    end
    state.shown = true
    if state.auth.user_id == "" or state.auth.access_token == "" then
        start_quick_connect()
    else
        load_current_layer()
    end
end

local function search()
    if options.url == "" then
        mp.osd_message("请先设置 Jellyfin 地址。", 5)
        return
    end
    local reopen = state.shown
    if reopen then close_menu(true) end
    invalidate_select(false)
    local session = state.select_session
    local pending_query
    input.get({
        prompt = "搜索 Jellyfin：",
        id = "jellyfin-search",
        submit = function(query)
            query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if query == "" then return end
            pending_query = query
            input.terminate()
        end,
        closed = function()
            if session ~= state.select_session then return end
            defer(function()
                if session ~= state.select_session then return end
                if pending_query then
                    state.layers = {
                        { kind = "root", title = "Jellyfin", selection = 1 },
                        {
                            kind = "search",
                            title = "搜索：" .. pending_query,
                            query = pending_query,
                            include_types = all_include_types,
                            recursive = true,
                            page = 0,
                            selection = 1,
                        },
                    }
                    state.shown = true
                    if state.auth.access_token == "" then start_quick_connect() else load_current_layer() end
                elseif reopen then
                    state.shown = true
                    load_current_layer()
                end
            end)
        end,
    })
end

local function active_session_from_path()
    local path = mp.get_property("path") or ""
    return state.playback.planned[path]
end

local function on_file_loaded()
    local entry = active_session_from_path()
    if not entry then
        state.playback.active = nil
        return
    end
    local session = {
        entry = entry,
        position_ticks = math.floor((resume_seconds(entry.item) or 0) * TICKS_PER_SECOND),
        duration_ticks = nil,
        is_paused = false,
        is_muted = false,
        subtitle_requests = {},
    }
    state.playback.active = session
    snapshot_session(session, false)
    local saved_ticks = math.floor((resume_seconds(entry.item) or 0) * TICKS_PER_SECOND)
    if saved_ticks > session.position_ticks then session.position_ticks = saved_ticks end
    enqueue_report("started", session)
    if entry.kind == "video" then load_external_subtitles(session) end
end

local function on_unload()
    snapshot_session(state.playback.active, false)
end

local function unpause_after_eof()
    if not mp.get_property_bool("pause") then return end
    state.playback.suppress_pause_report = true
    mp.set_property_bool("pause", false)
end

local function on_end_file(event)
    local ended = event and event.reason == "eof"
    local session = state.playback.active
    if not session then
        close_live_stream(active_session_from_path(), false)
        if ended then unpause_after_eof() end
        return
    end
    snapshot_session(session, ended)
    abort_subtitles(session)
    state.playback.active = nil
    if event and event.reason == "quit" then
        flush_stops_sync(session, false)
        close_live_stream(session.entry, true)
    else
        enqueue_report("stopped", session, event and event.reason == "error", function()
            close_live_stream(session.entry, false)
        end)
    end
    if ended then unpause_after_eof() end
end

local function report_progress(is_paused)
    local session = state.playback.active
    if not session then return end
    snapshot_session(session, false)
    if is_paused ~= nil then session.is_paused = is_paused == true end
    enqueue_report("progress", session)
end

local function on_shutdown()
    state.preparing_generation = state.preparing_generation + 1
    abort_requests(state.preparing_requests)
    cancel_menu_requests()
    if state.quick.active then cancel_quick_connect(false) end
    local session = state.playback.active
    if session then
        snapshot_session(session, false)
        abort_subtitles(session)
        state.playback.active = nil
        flush_stops_sync(session, false)
    else
        flush_stops_sync(nil, false)
    end
    close_all_live_streams_sync()
end

local function supported_mpv()
    local version = mp.get_property("mpv-version") or ""
    local major, minor = version:match("(%d+)%.(%d+)")
    major, minor = tonumber(major), tonumber(minor)
    return major and minor and (major > 0 or minor >= 39)
end

if not supported_mpv() then
    msg.error("mpv-jellyfin 需要 mpv 0.39.0 或更高版本。")
else
    mkdir(options.cache_path)
    mkdir(subtitle_directory)
    load_auth()

    mp.add_key_binding("Ctrl+j", "jf", toggle_menu)
    mp.add_key_binding("Ctrl+f", "jf_search", search)
    mp.add_key_binding("ESC", "jf_close", function()
        if state.shown then close_menu(true) end
    end)

    mp.observe_property("pause", "bool", function(_, paused)
        if state.playback.suppress_pause_report then
            state.playback.suppress_pause_report = false
            return
        end
        if paused ~= nil then report_progress(paused) end
    end)
    mp.register_event("seek", function() report_progress(nil) end)
    mp.add_periodic_timer(10, function()
        if state.playback.active and not mp.get_property_bool("pause") then report_progress(false) end
    end)
    mp.add_hook("on_unload", 50, on_unload)
    mp.register_event("file-loaded", on_file_loaded)
    mp.register_event("end-file", on_end_file)
    mp.register_event("shutdown", on_shutdown)

    if options.show_by_default == "on" then defer(toggle_menu) end
    if options.show_on_idle == "on" then
        mp.observe_property("idle-active", "bool", function(_, idle)
            if idle and not state.shown then toggle_menu() end
        end)
    end
end
