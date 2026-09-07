# mpv-jellyfin 使用说明

[简体中文](README.md) | [English](README.en.md)

## 安装

将 `scripts/jellyfin_client.lua` 复制到 mpv 的 `scripts` 目录。

如需调整选项，将 `script-opts/jellyfin_client.conf` 复制到 mpv 的 `script-opts` 目录；使用默认选项时无需配置文件。服务器地址在首次运行时输入。

mpv 目录结构示例：

```text
portable_config/
  scripts/
    jellyfin_client.lua
  script-opts/
    jellyfin_client.conf
```

## 首次运行

启动 mpv，然后按 `Ctrl+j` 打开 Jellyfin 菜单。

首次打开时输入服务器地址，例如 `https://jellyfin.example.com` 或 `http://192.168.1.40:8096/jellyfin`。如果没有已保存的令牌，脚本会启动 Jellyfin 快速连接。点击验证码可将其复制到系统剪贴板，然后在另一个已登录的 Jellyfin 客户端中完成授权。服务器地址、令牌和稳定的设备 ID 保存在 `~~state/jellyfin_auth.json` 中。验证码失效时，重新打开菜单即可申请新的验证码。

更换或纠正服务器地址时，先退出 mpv，删除状态目录中的 `jellyfin_auth.json`，再启动 mpv 并重新输入地址、登录。令牌失效后重新登录会保留已有地址和设备 ID。

## 快捷键

- `Ctrl+j`：打开或关闭 Jellyfin 菜单
- 原生菜单：使用 mpv 内置选择菜单，通过键盘、鼠标和文本过滤进行操作
- `Ctrl+f`：使用 mpv 内置文本输入搜索 Jellyfin 服务器；尚未登录时会先完成登录，再执行已提交的搜索
- `Esc`：关闭当前菜单

## 菜单行为

首页显示 Jellyfin 返回的全部媒体库及其最新内容，包括影视、音乐、照片和播放列表。直播电视显示频道入口，不在首页请求“最新”内容；电子书等 mpv 无法呈现的项目会被忽略。

可以通过 `jellyfin_client.conf` 中的 `home_latest_limit` 控制首页每个媒体库显示的最新项目数量。

对于电视剧媒体库，最新剧集会按所属系列去重，一次批量读取真实系列信息，并保持最新内容顺序。未能取得系列信息的项目暂不显示，媒体库入口仍保留。选择系列后会进入该系列的剧集列表。

`MyMediaExcludes` 与 `LatestItemsExcludes` 中出现的媒体库归入首页末尾的“其他”分组，不显示该媒体库的最新内容。没有被排除的媒体库时不显示“其他”。

媒体库和搜索结果使用分页显示。可以通过 `jellyfin_client.conf` 中的 `page_size` 设置每页项目数。剧集列表会完整加载，以便从选中的剧集开始准确排列全部后续剧集。

媒体项目使用观看状态前缀：`🔲` 表示未观看，`🔄` 表示观看中，`✅` 表示已观看。系列剧集列表先按最新入库时间显示未看完的剧集，再按剧集倒序显示已观看的剧集。

选择视频、音频或有声书后，mpv 会直接串流原始文件，并在 Jellyfin 保存了播放位置时自动续播。音频只播放当前选择的单曲；照片使用 Jellyfin 的原图接口并保持单张静态显示。从系列剧集列表选择某一集时，脚本会按时间顺序将该集及全部后续剧集加入 mpv 播放列表。

直播电视支持频道列表和当前节目标题。选择频道时脚本会向 Jellyfin 打开直播媒体源，并在停止、切台或退出时释放它。HTTP 直播使用静态播放；UDP/RTP 组播由 Jellyfin 接收，以音视频流复制方式转封装为 HTTP MPEG-TS，交给 mpv 解码，不重新编码、不烧录字幕。Jellyfin 所在网络须能接收组播，mpv 无需直接访问组播网络。客户端不回退到编码转码；mpv 无法解码的点播文件或直播源会播放失败。节目表、预约、录制和录像管理不在支持范围内。

视频、音频和直播播放期间，脚本会按顺序向 Jellyfin 上报播放状态；组播流复制上报为 DirectStream，其他播放上报为 DirectPlay。视频和音频在暂停和跳转时更新进度，普通视频还会添加 Jellyfin 提供的外置文本字幕。照片不创建播放会话。

所有配置选项请参阅 `script-opts/jellyfin_client.conf`。

## 依赖

- mpv `0.39.0` 或更高版本（使用原生 `mp.input.select` 菜单）
- mpv 原生控制台和菜单支持，即 `mp.input.get` 与 `mp.input.select`
- PATH 中可用的 `curl`

## 开发

诊断请求失败时可运行 `mpv --idle --log-file=mpv-jellyfin.log --msg-level=jellyfin_client=debug`。Windows 可将命令中的 `mpv` 换为 `mpv.exe`，日志写入当前目录。脚本日志包含 HTTP/curl 状态及错误原因。

使用兼容 Lua 5.1 的运行时执行无第三方依赖的 mock 测试：

```text
lua tests/jellyfin_client_test.lua scripts/jellyfin_client.lua
```

测试通过模拟 API 响应驱动公开的 mpv 快捷键和回调，覆盖快速连接、认证重置、“其他”分组、全媒体浏览、最新系列去重、分页、音视频续播、照片显示、组播流复制、直播资源释放、有序播放状态上报、字幕、分段视频、本地文件隔离和退出清理。测试不包含真实 mpv/Jellyfin 环境的集成验证，不能据此确定服务端版本兼容范围。
