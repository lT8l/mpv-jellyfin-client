local source_path = arg and arg[1] or "scripts/jellyfin_client.lua"

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "值不相等") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function assert_true(value, message)
    if not value then error(message or "断言失败", 2) end
end

local json_values = {}
local formatted_values = {}
local json_index = 0
local auth_content = "OLD_AUTH"
json_values.OLD_AUTH = {
    version = 2,
    device_id = "old-device",
    server_url = "http://jellyfin.test",
    user_id = "legacy-user",
    access_token = "legacy-token",
}
local real_io_open = io.open

io.open = function(path, mode)
    if path ~= "AUTH" then return real_io_open(path, mode) end
    if mode == "r" then
        if not auth_content then return nil end
        return {
            read = function() return auth_content end,
            close = function() end,
        }
    end
    return {
        write = function(_, value) auth_content = value end,
        close = function() end,
    }
end

local mock = {
    async = {},
    commands = {},
    keybindings = {},
    events = {},
    hooks = {},
    observers = {},
    timers = {},
    timeouts = {},
    messages = {},
    properties = {
        ["mpv-version"] = "mpv 0.39.0",
        pause = false,
        mute = false,
    },
    osd = {},
    subprocess_status = 0,
}

local function subprocess_args(record)
    local command = record.command or record
    return command.args or {}
end

local function command_url(record)
    local args = subprocess_args(record)
    return args and args[#args] or ""
end

local function command_body(record)
    local args = subprocess_args(record)
    for index, value in ipairs(args) do
        if value == "-d" then return formatted_values[args[index + 1]] end
    end
    return nil
end

local function command_method(record)
    local args = subprocess_args(record)
    for index, value in ipairs(args) do
        if value == "-X" then return args[index + 1] end
    end
end

local function command_header(record, prefix)
    local args = subprocess_args(record)
    for index, value in ipairs(args) do
        local header = args[index + 1]
        if value == "-H" and type(header) == "string" and header:sub(1, #prefix) == prefix then
            return header
        end
    end
end

local function next_request(pattern)
    for _, record in ipairs(mock.async) do
        if not record.completed and not record.aborted and command_url(record):find(pattern, 1, true) then
            return record
        end
    end
    error("找不到异步请求：" .. pattern, 2)
end

local function respond(record, value, status)
    assert_true(record and not record.completed, "请求已经完成")
    record.completed = true
    local body = ""
    if value ~= nil then
        json_index = json_index + 1
        body = "RESPONSE_" .. tostring(json_index)
        json_values[body] = value
    end
    record.callback(true, { status = 0, stdout = body .. "\n" .. tostring(status or 200) }, nil)
end

local function complete_raw(record)
    assert_true(record and not record.completed, "请求已经完成")
    record.completed = true
    record.callback(true, { status = 0, stdout = "" }, nil)
end

local function find_label(labels, wanted)
    for index, label in ipairs(labels or {}) do
        if label == wanted then return index end
    end
    return nil
end

local input_mock = { current = nil, terminate_count = 0 }

function input_mock.select(specification)
    specification._mock_kind = "select"
    local submit = specification.submit
    if submit then
        specification.submit = function(...)
            submit(...)
            if input_mock.current == specification then input_mock.current = nil end
        end
    end
    input_mock.current = specification
end

function input_mock.get(specification)
    specification._mock_kind = "get"
    input_mock.current = specification
end

function input_mock.terminate()
    input_mock.terminate_count = input_mock.terminate_count + 1
    input_mock.current = nil
end

local utils_mock = {}

function utils_mock.parse_json(value)
    local parsed = json_values[value]
    if parsed == nil then return nil, "unknown JSON fixture" end
    return parsed
end

function utils_mock.format_json(value)
    json_index = json_index + 1
    local token = "JSON_" .. tostring(json_index)
    json_values[token] = value
    formatted_values[token] = value
    return token
end

function utils_mock.join_path(left, right)
    return tostring(left) .. "/" .. tostring(right)
end

function utils_mock.getpid() return 42 end

local options_mock = {}
function options_mock.read_options(options)
    options.url = "http://jellyfin.test"
    options.cache_path = "CACHE"
    options.home_latest_limit = 2
    options.page_size = 2
end

local message_mock = {}
for _, level in ipairs({ "error", "warn", "info", "debug", "verbose", "trace" }) do
    message_mock[level] = function(message)
        mock.messages[#mock.messages + 1] = { level = level, text = tostring(message or "") }
    end
end

package.preload["mp.options"] = function() return options_mock end
package.preload["mp.utils"] = function() return utils_mock end
package.preload["mp.msg"] = function() return message_mock end
package.preload["mp.input"] = function() return input_mock end

mp = {}

function mp.get_script_name() return "jellyfin_client" end
function mp.get_time() return 123.5 end

function mp.get_property(name, default)
    local value = mock.properties[name]
    if value == nil then return default end
    return tostring(value)
end

function mp.get_property_number(name, default)
    local value = mock.properties[name]
    if value == nil then return default end
    return tonumber(value)
end

function mp.get_property_bool(name, default)
    local value = mock.properties[name]
    if value == nil then return default end
    return value == true
end

function mp.command_native(command)
    if command[1] == "expand-path" then
        if tostring(command[2]):find("jellyfin_auth.json", 1, true) then return "AUTH" end
        return command[2]
    end
    mock.commands[#mock.commands + 1] = command
    if command.name == "subprocess" then return { status = mock.subprocess_status, stdout = "" } end
    return {}
end

function mp.set_property_bool(name, value)
    mock.properties[name] = value == true
    local callback = mock.observers[name]
    if callback then callback(name, value == true) end
end

function mp.command_native_async(command, callback)
    local record = { command = command, callback = callback, completed = false, aborted = false }
    mock.async[#mock.async + 1] = record
    return record
end

function mp.abort_async_command(record)
    if record then record.aborted = true end
end

function mp.commandv(...)
    mock.commands[#mock.commands + 1] = { ... }
end

function mp.add_timeout(delay, callback)
    local timer = { delay = delay, callback = callback, active = true }
    function timer:kill() self.active = false end
    mock.timeouts[#mock.timeouts + 1] = timer
    return timer
end

local function run_timeouts()
    local count = 0
    while true do
        local pending
        for _, timer in ipairs(mock.timeouts) do
            if timer.active then pending = timer; break end
        end
        if not pending then return end
        pending.active = false
        pending.callback()
        count = count + 1
        if count > 100 then error("延迟任务未收敛", 2) end
    end
end

local function active_timeout_count()
    local count = 0
    for _, timer in ipairs(mock.timeouts) do
        if timer.active then count = count + 1 end
    end
    return count
end

local function submit_current(value)
    local specification = input_mock.current
    assert_true(specification and specification.submit, "当前没有可提交的输入")
    local timeout_count = active_timeout_count()
    local terminate_count = input_mock.terminate_count
    specification.submit(value)
    if specification._mock_kind == "select" then
        assert_equal(input_mock.terminate_count, terminate_count, "select 提交不应手动 terminate")
    end
    assert_equal(input_mock.current, nil, "提交后输入界面没有关闭")
    assert_equal(active_timeout_count(), timeout_count, "输入关闭前提前安排了后续动作")
    specification.closed()
    assert_true(active_timeout_count() > timeout_count, "输入关闭后没有安排后续动作")
    run_timeouts()
end

function mp.add_periodic_timer(_, callback)
    local timer = { callback = callback, active = true }
    function timer:kill() self.active = false end
    mock.timers[#mock.timers + 1] = timer
    return timer
end

function mp.add_key_binding(_, name, callback)
    mock.keybindings[name] = callback
end

function mp.register_event(name, callback)
    mock.events[name] = callback
end

function mp.add_hook(name, _, callback)
    mock.hooks[name] = callback
end

function mp.observe_property(name, _, callback)
    mock.observers[name] = callback
end

function mp.osd_message(message)
    mock.osd[#mock.osd + 1] = message
end

dofile(source_path)

assert_true(mock.keybindings.jf, "未注册 Ctrl+J 菜单")
assert_true(mock.keybindings.jf_search, "未注册 Ctrl+F 搜索")
assert_true(auth_content, "首次启动没有写入认证状态")
local initial_auth = json_values[auth_content]
assert_equal(initial_auth.version, 3, "认证格式版本错误")
assert_true(type(initial_auth.device_id) == "string" and initial_auth.device_id ~= "", "设备 ID 未生成")
assert_equal(initial_auth.server_url, "http://jellyfin.test", "新认证没有绑定当前服务器")
assert_equal(initial_auth.user_id, "", "旧认证用户仍被复用")
assert_equal(initial_auth.access_token, "", "旧认证令牌仍被复用")
assert_true(initial_auth.device_id ~= "old-device", "旧设备 ID 仍被复用")

mock.keybindings.jf()
local quick_initiate = next_request("/QuickConnect/Initiate")
assert_equal(command_method(quick_initiate), "POST", "快速连接初始化方法错误")
assert_true(command_header(quick_initiate, "Authorization: MediaBrowser "),
    "快速连接初始化缺少客户端认证头")
assert_equal(command_header(quick_initiate, "Content-Length:"), "Content-Length: 0",
    "快速连接初始化缺少空请求体声明")
respond(quick_initiate, { Code = "ABCD12", Secret = "secret" })
assert_true(input_mock.current.prompt:find("快速连接", 1, true), "未显示快速连接菜单")
assert_true(input_mock.current.items[1]:find("点击复制", 1, true), "登录码菜单缺少复制入口")
local command_count_before_copy = #mock.commands
local quick_menu = input_mock.current
local quick_poll = next_request("/QuickConnect/Connect")
assert_equal(command_method(quick_poll), "GET", "快速连接轮询方法错误")
assert_equal(command_header(quick_poll, "Authorization:"), nil, "快速连接轮询意外附带认证头")
local quick_timeout_count = active_timeout_count()
local terminate_count_before_copy = input_mock.terminate_count
quick_menu.submit(1)
assert_equal(input_mock.terminate_count, terminate_count_before_copy, "登录码 select 提交不应手动 terminate")
assert_true(#mock.commands > command_count_before_copy, "点击登录码没有调用剪贴板命令")
assert_equal(input_mock.current, nil, "复制后旧登录码菜单没有关闭")
assert_equal(active_timeout_count(), quick_timeout_count, "登录码菜单关闭前提前安排了重开")
quick_menu.closed()
assert_true(not quick_poll.aborted, "关闭旧登录码菜单错误中止了快速连接轮询")
assert_equal(input_mock.current, nil, "旧登录码关闭回调内提前创建了新菜单")
run_timeouts()
assert_true(input_mock.current.items[1]:find("已复制", 1, true), "登录码复制成功后没有状态反馈")

mock.subprocess_status = 1
quick_menu = input_mock.current
quick_menu.submit(1)
quick_menu.closed()
assert_true(not quick_poll.aborted, "复制失败后错误中止了快速连接轮询")
run_timeouts()
assert_true(input_mock.current.items[1]:find("复制失败", 1, true), "剪贴板命令失败后没有手动输入提示")
mock.subprocess_status = 0
respond(next_request("/QuickConnect/Connect"), { Authenticated = true })
local quick_authenticate = next_request("/Users/AuthenticateWithQuickConnect")
assert_equal(command_method(quick_authenticate), "POST", "快速连接换取令牌方法错误")
assert_true(command_header(quick_authenticate, "Authorization: MediaBrowser "),
    "快速连接换取令牌缺少客户端认证头")
assert_equal(command_header(quick_authenticate, "Content-Type:"), "Content-Type: application/json",
    "快速连接换取令牌缺少 JSON 类型")
respond(quick_authenticate, {
    AccessToken = "token",
    User = { Id = "user" },
})
run_timeouts()

local user_fixture = {
    Configuration = {
        MyMediaExcludes = { "hidden" },
        LatestItemsExcludes = { "no-latest" },
    },
}
local views_fixture = {
    Items = {
        { Id = "movies", Name = "电影", Type = "CollectionFolder", CollectionType = "movies" },
        { Id = "tv", Name = "剧集", Type = "CollectionFolder", CollectionType = "tvshows" },
        { Id = "music", Name = "音乐", Type = "CollectionFolder", CollectionType = "music" },
        { Id = "photos", Name = "照片", Type = "CollectionFolder", CollectionType = "photos" },
        { Id = "live", Name = "直播电视", Type = "CollectionFolder", CollectionType = "livetv" },
        { Id = "no-latest", Name = "无最新", Type = "CollectionFolder", CollectionType = "homevideos" },
        { Id = "hidden", Name = "家庭视频", Type = "CollectionFolder", CollectionType = "homevideos" },
    },
    TotalRecordCount = 7,
}

local function respond_root_menu(user)
    user = user or user_fixture
    respond(next_request("/Users/user"), user)
    respond(next_request("/Users/user/Views"), views_fixture)
    respond(next_request("ParentId=movies"), {
        { Id = "latest", Name = "新片", Type = "Movie", IsFolder = false, UserData = { Played = false } },
    })
    respond(next_request("ParentId=tv"), {
        { Id = "e1", Name = "第一集", Type = "Episode", SeriesId = "series", SeriesName = "同剧" },
        { Id = "e2", Name = "第二集", Type = "Episode", SeriesId = "series", SeriesName = "同剧" },
    })
    respond(next_request("ParentId=music"), {
        { Id = "latest-audio", Name = "新歌", Type = "Audio", MediaType = "Audio", IsFolder = false },
    })
    respond(next_request("ParentId=photos"), {
        { Id = "latest-photo", Name = "新照片", Type = "Photo", MediaType = "Photo", IsFolder = false },
    })
    if not (user.Configuration and user.Configuration.LatestItemsExcludes) then
        respond(next_request("ParentId=no-latest"), {})
        respond(next_request("ParentId=hidden"), {})
    end
    respond(next_request("Ids=series"), {
        Items = {
            {
                Id = "series",
                Name = "同剧",
                Type = "Series",
                IsFolder = true,
                RecursiveItemCount = 10,
                ChildCount = 2,
                UserData = { UnplayedItemCount = 3 },
            },
        },
    })
end

local function has_request(pattern)
    for _, record in ipairs(mock.async) do
        if command_url(record):find(pattern, 1, true) then return true end
    end
    return false
end

local function request_count(pattern)
    local count = 0
    for _, record in ipairs(mock.async) do
        if command_url(record):find(pattern, 1, true) then count = count + 1 end
    end
    return count
end

respond_root_menu()
assert_equal(request_count("Ids=series"), 1, "首页系列信息没有合并为一次批量请求")

local root_labels = input_mock.current.items
assert_true(find_label(root_labels, "媒体库 · 电影"), "首页缺少电影库")
assert_true(find_label(root_labels, "媒体库 · 剧集"), "首页缺少剧集库")
assert_true(find_label(root_labels, "媒体库 · 音乐"), "首页缺少音乐库")
assert_true(find_label(root_labels, "媒体库 · 照片"), "首页缺少照片库")
assert_true(find_label(root_labels, "媒体库 · 直播电视"), "首页缺少直播电视")
assert_true(not find_label(root_labels, "媒体库 · 无最新"), "LatestItemsExcludes 没有移入其他")
assert_true(find_label(root_labels, "其他"), "首页缺少其他分组")
assert_true(not has_request("ParentId=no-latest"), "排除媒体库仍请求了最新内容")
assert_true(not has_request("ParentId=hidden"), "隐藏媒体库仍请求了最新内容")
local series_count = 0
for _, label in ipairs(root_labels) do if label == "🔄 同剧" then series_count = series_count + 1 end end
assert_equal(series_count, 1, "电视剧最新内容没有按 SeriesId 去重")

submit_current(find_label(root_labels, "其他"))
assert_true(find_label(input_mock.current.items, "媒体库 · 无最新"), "其他分组缺少 LatestItemsExcludes 媒体库")
assert_true(find_label(input_mock.current.items, "媒体库 · 家庭视频"), "其他分组缺少 MyMediaExcludes 媒体库")
submit_current(find_label(input_mock.current.items, "‹ 返回"))
respond_root_menu()
root_labels = input_mock.current.items

submit_current(find_label(root_labels, "媒体库 · 直播电视"))
local quick_connect_count = request_count("/QuickConnect/Initiate")
respond(next_request("/LiveTv/Channels"), nil, 403)
local preserved_auth = json_values[auth_content]
assert_equal(preserved_auth.access_token, "token", "403 错误清除了有效令牌")
assert_equal(preserved_auth.user_id, "user", "403 错误清除了有效用户")
assert_equal(request_count("/QuickConnect/Initiate"), quick_connect_count, "403 错误触发了重新认证")
assert_true(mock.osd[#mock.osd]:find("无权", 1, true), "403 没有显示权限提示")

mock.keybindings.jf()
respond(next_request("/LiveTv/Channels"), {
    Items = {
        {
            Id = "channel",
            Name = "新闻频道",
            Type = "LiveTvChannel",
            IsFolder = false,
            CurrentProgram = { Name = "午间新闻" },
        },
    },
    StartIndex = 0,
    TotalRecordCount = 1,
})
assert_true(find_label(input_mock.current.items, "新闻频道 · 午间新闻"), "直播频道没有显示当前节目")
submit_current(find_label(input_mock.current.items, "‹ 返回"))
respond_root_menu({ Configuration = {} })
root_labels = input_mock.current.items
assert_true(not find_label(root_labels, "其他"), "没有排除媒体库时仍显示其他分组")

submit_current(find_label(root_labels, "媒体库 · 电影"))
local first_page = next_request("ParentId=movies")
assert_true(command_url(first_page):find("Limit=2", 1, true), "分页大小未传给服务器")
assert_true(command_url(first_page):find("StartIndex=0", 1, true), "第一页起始索引错误")
respond(first_page, {
    Items = {
        { Id = "m1", Name = "电影一", Type = "Movie", IsFolder = false, UserData = {} },
        { Id = "m2", Name = "电影二", Type = "Movie", IsFolder = false, UserData = {} },
    },
    StartIndex = 0,
    TotalRecordCount = 3,
})

local page_one_labels = input_mock.current.items
submit_current(find_label(page_one_labels, "下一页 ›"))
local second_page = next_request("StartIndex=2")
respond(second_page, {
    Items = {
        {
            Id = "m3",
            Name = "电影三",
            Type = "Movie",
            IsFolder = false,
            MediaSourceId = "video-source",
            MediaSources = {
                { Id = "wrong-source" },
                { Id = "video-source" },
            },
            UserData = { PlaybackPositionTicks = 10000000, Played = false },
        },
    },
    StartIndex = 2,
    TotalRecordCount = 3,
})

local page_two_labels = input_mock.current.items
submit_current(find_label(page_two_labels, "🔄 电影三"))

local loadfile
for _, command in ipairs(mock.commands) do
    if command[1] == "loadfile" then loadfile = command end
end
assert_true(loadfile, "选择电影后没有创建 mpv 播放项")
assert_equal(loadfile[2], "http://jellyfin.test/Videos/m3/stream?static=true&MediaSourceId=video-source",
    "视频没有使用原实现的静态流路径")
assert_equal(loadfile[5]["http-header-fields"], 'Authorization: MediaBrowser Token="token"',
    "视频没有使用原实现的 Token-only 请求头")
assert_equal(loadfile[5].start, "1", "一秒续播位置被错误过滤")

mock.properties.path = loadfile[2]
mock.properties["time-pos"] = 10
mock.properties.duration = 100
mock.events["file-loaded"]()

local started = next_request("/Sessions/Playing")
assert_equal(command_method(started), "POST", "播放开始上报方法错误")
assert_true(command_header(started, "Authorization: MediaBrowser Token="), "播放上报缺少令牌请求头")
assert_equal(command_header(started, "Content-Type:"), "Content-Type: application/json",
    "播放上报缺少 JSON 类型")
local metadata = next_request("Ids=m3")
respond(metadata, {
    Items = {
        {
            Id = "m3",
            MediaSources = {
                {
                    Id = "wrong-source",
                    MediaStreams = {},
                },
                {
                    Id = "video-source",
                    MediaStreams = {
                        {
                            Index = 4,
                            Codec = "srt",
                            IsTextSubtitleStream = true,
                            IsExternal = true,
                            DisplayTitle = "中文",
                            Language = "chi",
                        },
                    },
                },
            },
        },
    },
})
local subtitle = next_request("/Subtitles/4/Stream.srt")
assert_true(command_url(subtitle):find("/video-source/Subtitles/", 1, true),
    "字幕没有匹配实际播放的媒体源")
complete_raw(subtitle)

mock.properties["time-pos"] = 20
mock.properties.pause = true
mock.observers.pause(nil, true)
mock.properties["time-pos"] = 30
mock.events.seek()
respond(started, nil, 204)

local progress = next_request("/Sessions/Playing/Progress")
assert_equal(command_body(progress).PositionTicks, 300000000, "进度事件未合并为最新位置")

mock.properties["time-pos"] = 99
mock.hooks.on_unload()
mock.events["end-file"]({ reason = "eof" })
assert_equal(mock.properties.pause, false, "自然 EOF 没有解除暂停")
respond(progress, nil, 403)
assert_equal(json_values[auth_content].access_token, "token", "播放状态上报 403 错误清除了有效令牌")
local stopped = next_request("/Sessions/Playing/Stopped")
assert_equal(command_body(stopped).PositionTicks, 1000000000, "EOF 没有上报完整时长")
assert_equal(command_body(stopped).Failed, false, "正常结束被标记为失败")

local report_count = #mock.async
mock.properties.path = "C:/video/local.mkv"
mock.events["file-loaded"]()
mock.observers.pause(nil, false)
assert_equal(#mock.async, report_count, "本地文件继承了 Jellyfin 播放会话")
respond(stopped, nil, 204)

local subtitle_added = false
for _, command in ipairs(mock.commands) do
    if command[1] == "sub-add" then subtitle_added = true end
end
assert_true(subtitle_added, "当前会话的外置字幕没有加入 mpv")

mock.keybindings.jf()
local refreshed_page = next_request("StartIndex=2")
respond(refreshed_page, {
    Items = {
        {
            Id = "multipart",
            Name = "分段电影",
            Type = "Movie",
            IsFolder = false,
            PartCount = 2,
            UserData = { PlaybackPositionTicks = 10000000 },
        },
    },
    StartIndex = 2,
    TotalRecordCount = 3,
})
submit_current(find_label(input_mock.current.items, "🔄 分段电影"))
respond(next_request("/Videos/multipart/AdditionalParts"), {
    Items = {
        {
            Id = "part2",
            Name = "实际第二段",
            Type = "Movie",
            IsFolder = false,
            UserData = { PlaybackPositionTicks = 50000000 },
        },
    },
})

local playlist_loads = {}
for _, command in ipairs(mock.commands) do
    if command[1] == "loadfile" then playlist_loads[#playlist_loads + 1] = command end
end
local part_one = playlist_loads[#playlist_loads - 1]
local part_two = playlist_loads[#playlist_loads]
assert_equal(part_one[2], "http://jellyfin.test/Videos/multipart/stream?static=true", "第一段地址错误")
assert_equal(part_two[2], "http://jellyfin.test/Videos/part2/stream?static=true", "第二段没有使用真实 DTO ID")
assert_equal(part_two[5].start, "5", "第二段错误继承了父项续播位置")

mock.properties.path = part_one[2]
mock.properties["time-pos"] = 2
mock.properties.duration = 10
mock.events["file-loaded"]()
respond(next_request("Ids=multipart"), { Items = { { Id = "multipart", MediaSources = {} } } })
respond(next_request("/Sessions/Playing"), nil, 204)
mock.properties["time-pos"] = 4
mock.hooks.on_unload()
mock.events["end-file"]({ reason = "eof" })
respond(next_request("/Sessions/Playing/Stopped"), nil, 204)

local function submit_search(query, items)
    mock.keybindings.jf_search()
    submit_current(query)
    respond(next_request("SearchTerm=" .. query), {
        Items = items,
        StartIndex = 0,
        TotalRecordCount = #items,
    })
end

local function last_loadfile()
    for index = #mock.commands, 1, -1 do
        if mock.commands[index][1] == "loadfile" then return mock.commands[index] end
    end
end

submit_search("song", {
    {
        Id = "song",
        Name = "单曲",
        Type = "Audio",
        MediaType = "Audio",
        IsFolder = false,
        MediaSourceId = "audio-source",
        UserData = { PlaybackPositionTicks = 20000000 },
    },
})
submit_current(find_label(input_mock.current.items, "🔄 单曲"))
local audio_load = last_loadfile()
assert_equal(audio_load[2], "http://jellyfin.test/Audio/song/stream?static=true&MediaSourceId=audio-source",
    "音频没有使用最小静态流路径")
assert_equal(audio_load[5]["http-header-fields"], 'Authorization: MediaBrowser Token="token"',
    "音频没有使用 Token-only 请求头")
assert_equal(audio_load[5].start, "2", "音频没有使用续播位置")
mock.properties.path = audio_load[2]
mock.properties["time-pos"] = 2
mock.properties.duration = 20
mock.events["file-loaded"]()
assert_true(not has_request("Ids=song"), "音频错误请求了视频字幕")
respond(next_request("/Sessions/Playing"), nil, 204)
mock.properties["time-pos"] = 20
mock.events["end-file"]({ reason = "eof" })
respond(next_request("/Sessions/Playing/Stopped"), nil, 204)

submit_search("photo", {
    { Id = "photo", Name = "单张照片", Type = "Photo", MediaType = "Photo", IsFolder = false },
})
submit_current(find_label(input_mock.current.items, "🔲 单张照片"))
local photo_load = last_loadfile()
assert_true(photo_load[2]:find("/Items/photo/Images/Primary", 1, true), "照片没有使用 Primary 图片接口")
assert_equal(photo_load[5]["http-header-fields"], 'Authorization: MediaBrowser Token="token"',
    "照片没有使用 Token-only 请求头")
assert_equal(photo_load[5]["image-display-duration"], "inf", "照片没有保持静态显示")
local photo_request_count = #mock.async
mock.properties.path = photo_load[2]
mock.events["file-loaded"]()
assert_equal(#mock.async, photo_request_count, "照片错误创建了播放会话")

submit_search("playlist", {
    { Id = "playlist", Name = "播放列表", Type = "Playlist", IsFolder = true },
})
submit_current(find_label(input_mock.current.items, "🔲 播放列表"))
local playlist_page_one = next_request("/Playlists/playlist/Items")
local playlist_page_one_url = command_url(playlist_page_one)
assert_true(playlist_page_one_url:find("StartIndex=0", 1, true), "播放列表第一页起始索引错误")
assert_true(playlist_page_one_url:find("Limit=2", 1, true), "播放列表没有使用分页大小")
assert_true(not playlist_page_one_url:find("SortBy=", 1, true), "播放列表错误覆盖了服务端顺序")
assert_true(not playlist_page_one_url:find("IncludeItemTypes=", 1, true), "播放列表错误限制了项目类型")
respond(playlist_page_one, {
    Items = {
        { Id = "playlist-song-2", Name = "第二首", Type = "Audio", MediaType = "Audio", IsFolder = false },
        { Id = "playlist-song-1", Name = "第一首", Type = "Audio", MediaType = "Audio", IsFolder = false },
    },
    StartIndex = 0,
    TotalRecordCount = 3,
})
assert_equal(input_mock.current.items[2], "🔲 第二首", "播放列表没有保持服务端项目顺序")
assert_equal(input_mock.current.items[3], "🔲 第一首", "播放列表项目顺序被重新排序")
submit_current(find_label(input_mock.current.items, "下一页 ›"))
local playlist_page_two = next_request("/Playlists/playlist/Items")
assert_true(command_url(playlist_page_two):find("StartIndex=2", 1, true), "播放列表第二页起始索引错误")
respond(playlist_page_two, {
    Items = {
        { Id = "playlist-song-3", Name = "第三首", Type = "Audio", MediaType = "Audio", IsFolder = false },
    },
    StartIndex = 2,
    TotalRecordCount = 3,
})
assert_true(find_label(input_mock.current.items, "🔲 第三首"), "播放列表第二页缺少项目")

submit_search("blocked-channel", {
    {
        Id = "blocked-channel",
        Name = "不可直连频道",
        Type = "LiveTvChannel",
        IsFolder = false,
    },
})
local load_before_rejected_live = last_loadfile()
submit_current(find_label(input_mock.current.items, "不可直连频道"))
local rejected_playback_info = next_request("/Items/blocked-channel/PlaybackInfo")
respond(rejected_playback_info, {
    PlaySessionId = "rejected-live-session",
    MediaSources = {
        {
            Id = "opened-transcode-source",
            LiveStreamId = "opened-transcode-stream",
            TranscodingUrl = "/Videos/ActiveEncodings/rejected/master.m3u8",
        },
        {
            Id = "different-direct-source",
            SupportsDirectPlay = true,
        },
    },
})
assert_equal(last_loadfile(), load_before_rejected_live,
    "直播错误播放了未实际打开的另一个媒体源")
local rejected_live_close = next_request("/LiveStreams/Close")
assert_equal(command_method(rejected_live_close), "POST", "直播关闭方法错误")
assert_true(command_header(rejected_live_close, "Authorization: MediaBrowser Token="),
    "直播关闭缺少令牌请求头")
assert_equal(command_header(rejected_live_close, "Content-Length:"), "Content-Length: 0",
    "直播关闭缺少空请求体声明")
assert_true(command_url(rejected_live_close):find("opened%-transcode%-stream"),
    "不可直连时没有关闭 Jellyfin 实际打开的直播源")
respond(rejected_live_close, nil, 204)

local function start_live(stream_id)
    submit_search("channel", {
        {
            Id = "channel",
            Name = "新闻频道",
            Type = "LiveTvChannel",
            IsFolder = false,
            CurrentProgram = { Name = "午间新闻" },
        },
    })
    submit_current(find_label(input_mock.current.items, "新闻频道 · 午间新闻"))
    local playback_info = next_request("/Items/channel/PlaybackInfo")
    local body = command_body(playback_info)
    assert_equal(body.AutoOpenLiveStream, true, "直播没有自动打开媒体源")
    assert_equal(body.EnableTranscoding, false, "直播错误启用了转码")
    respond(playback_info, {
        PlaySessionId = "live-session-" .. stream_id,
        MediaSources = {
            {
                Id = "live-source",
                LiveStreamId = stream_id,
                SupportsDirectPlay = true,
            },
        },
    })
    local live_load = last_loadfile()
    assert_true(live_load[2]:find("/Videos/channel/stream", 1, true), "直播地址错误")
    assert_true(live_load[2]:find("LiveStreamId=" .. stream_id, 1, true), "直播地址缺少 LiveStreamId")
    assert_true(live_load[2]:find("PlaySessionId=live-session-" .. stream_id, 1, true), "直播地址缺少服务端会话 ID")
    assert_true(live_load[2]:find("MediaSourceId=live-source", 1, true), "直播地址缺少媒体源 ID")
    assert_true(live_load[2]:find("DeviceId=", 1, true), "直播地址缺少设备 ID")
    assert_equal(live_load[5]["http-header-fields"], 'Authorization: MediaBrowser Token="token"',
        "直播没有使用 Token-only 请求头")
    mock.properties.path = live_load[2]
    mock.properties["time-pos"] = 8
    mock.properties.duration = nil
    mock.events["file-loaded"]()
    local live_started = next_request("/Sessions/Playing")
    assert_equal(command_body(live_started).CanSeek, false, "直播错误标记为可跳转")
    assert_equal(command_body(live_started).PositionTicks, 0, "直播错误上报了文件时间轴")
    assert_equal(command_body(live_started).LiveStreamId, stream_id, "直播开始上报缺少 LiveStreamId")
    respond(live_started, nil, 204)
    mock.events.seek()
    local live_progress = next_request("/Sessions/Playing/Progress")
    assert_equal(command_body(live_progress).LiveStreamId, stream_id, "直播进度上报缺少 LiveStreamId")
    respond(live_progress, nil, 204)
    return live_load
end

start_live("stream-one")
mock.events["end-file"]({ reason = "eof" })
local live_stopped = next_request("/Sessions/Playing/Stopped")
assert_equal(command_body(live_stopped).LiveStreamId, "stream-one", "直播停止上报缺少 LiveStreamId")
respond(live_stopped, nil, 204)
local close_one = next_request("/LiveStreams/Close")
assert_true(command_url(close_one):find("stream-one", 1, true), "停止直播没有关闭正确的媒体源")
respond(close_one, nil, 204)

start_live("stream-two")
mock.events["end-file"]({ reason = "eof" })
respond(next_request("/Sessions/Playing/Stopped"), nil, 204)
local failed_close = next_request("/LiveStreams/Close")
assert_true(command_url(failed_close):find("stream-two", 1, true), "直播关闭失败用例选错了媒体源")
respond(failed_close, nil, 500)
start_live("stream-three")
mock.events.shutdown()

local flushed_stop = false
local flushed_live = false
local flushed_current_live = false
for _, command in ipairs(mock.commands) do
    if command.name == "subprocess" and command.args and
        tostring(command.args[#command.args]):find("/Sessions/Playing/Stopped", 1, true) then
        flushed_stop = true
        assert_equal(command_method(command), "POST", "shutdown 停止上报方法错误")
        assert_true(command_header(command, "Authorization: MediaBrowser Token="),
            "shutdown 停止上报缺少令牌请求头")
        assert_equal(command_header(command, "Content-Type:"), "Content-Type: application/json",
            "shutdown 停止上报缺少 JSON 类型")
        assert_true(command_body(command).ItemId, "shutdown 停止上报缺少媒体 ID")
        assert_equal(command_body(command).LiveStreamId, "stream-three",
            "shutdown 直播停止上报缺少 LiveStreamId")
    end
    if command.name == "subprocess" and command.args and
        tostring(command.args[#command.args]):find("/LiveStreams/Close", 1, true) and
        tostring(command.args[#command.args]):find("stream%-two") then
        flushed_live = true
        assert_equal(command_method(command), "POST", "shutdown 补关直播方法错误")
        assert_true(command_header(command, "Authorization: MediaBrowser Token="),
            "shutdown 补关直播缺少令牌请求头")
        assert_equal(command_header(command, "Content-Length:"), "Content-Length: 0",
            "shutdown 补关直播缺少空请求体声明")
    end
    if command.name == "subprocess" and command.args and
        tostring(command.args[#command.args]):find("/LiveStreams/Close", 1, true) and
        tostring(command.args[#command.args]):find("stream%-three") then
        flushed_current_live = true
        assert_equal(command_method(command), "POST", "shutdown 当前直播关闭方法错误")
        assert_true(command_header(command, "Authorization: MediaBrowser Token="),
            "shutdown 当前直播关闭缺少令牌请求头")
        assert_equal(command_header(command, "Content-Length:"), "Content-Length: 0",
            "shutdown 当前直播关闭缺少空请求体声明")
    end
end
assert_true(flushed_stop, "shutdown 没有同步上报当前播放已停止")
assert_true(flushed_live, "shutdown 没有补关异步关闭失败的直播媒体源")
assert_true(flushed_current_live, "shutdown 没有同步关闭当前直播媒体源")

local persisted_auth = json_values[auth_content]
assert_equal(persisted_auth.version, 3, "登录成功后没有保存 v3 认证")
assert_equal(persisted_auth.server_url, "http://jellyfin.test", "登录成功后认证没有绑定服务器")
assert_equal(persisted_auth.user_id, "user", "登录成功后没有保存用户 ID")
assert_equal(persisted_auth.access_token, "token", "登录成功后没有保存访问令牌")

mock.keybindings = {}
dofile(source_path)
assert_true(mock.keybindings.jf, "重新加载脚本后没有注册菜单")
mock.keybindings.jf()
local reused_user = next_request("/Users/user")
local reused_views = next_request("/Users/user/Views")
assert_true(command_header(reused_user, "Authorization: MediaBrowser Token=\"token\""),
    "重新加载后没有复用有效 v3 令牌")
respond(reused_user, nil, 401)
assert_true(reused_views.aborted, "401 没有立即中止同批首页请求")
local cleared_after_401 = json_values[auth_content]
assert_equal(cleared_after_401.user_id, "", "401 没有清除用户 ID")
assert_equal(cleared_after_401.access_token, "", "401 没有清除访问令牌")

local reconnect_initiate = next_request("/QuickConnect/Initiate")
respond(reconnect_initiate, { Code = "CANCEL", Secret = "cancel-secret" })
local cancel_menu = input_mock.current
local canceled_poll = next_request("/QuickConnect/Connect")
local quick_timer = mock.timers[#mock.timers]
input_mock.current = nil
cancel_menu.closed()
assert_true(canceled_poll.aborted, "主动关闭快速连接没有中止轮询请求")
assert_equal(quick_timer.active, false, "主动关闭快速连接没有停止轮询定时器")

mock.properties["mpv-version"] = "mpv 0.38.0"
mock.keybindings = {}
local message_start = #mock.messages
dofile(source_path)
assert_equal(mock.keybindings.jf, nil, "mpv 0.38 错误启用了客户端")
local version_error = false
for index = message_start + 1, #mock.messages do
    local message = mock.messages[index]
    if message.level == "error" and message.text:find("0.39.0", 1, true) then
        version_error = true
        break
    end
end
assert_true(version_error, "mpv 0.38 没有报告最低版本要求")

print("jellyfin_client_test: ok")
