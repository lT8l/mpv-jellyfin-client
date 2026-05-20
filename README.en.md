# mpv-jellyfin usage

[简体中文](README.md) | [English](README.en.md)

## Install

Copy `scripts/jellyfin_client.lua` to your mpv `scripts` directory.

Copy `script-opts/jellyfin_client.conf` to your mpv `script-opts` directory, then set `url` to your Jellyfin server address.

Example mpv layout:

```text
portable_config/
  scripts/
    jellyfin_client.lua
  script-opts/
    jellyfin_client.conf
```

## First run

Start mpv and press `Ctrl+j` to open the Jellyfin menu.

If no saved token exists, the script starts Jellyfin Quick Connect. Select the displayed code to copy it to the system clipboard, then authorize it from another logged-in Jellyfin client. The token and a stable device ID are saved in mpv's state directory.

The current authentication format is version 3. Older authentication data is neither migrated nor reused; after upgrading, open the menu and sign in once through Quick Connect.

## Controls

- `Ctrl+j`: open or close the Jellyfin menu
- Native menu controls: use mpv's built-in select menu with keyboard, mouse, and filtering support
- `Ctrl+f`: search the Jellyfin server using mpv's built-in text input
- `Esc`: close the current menu

## Menu behavior

The root menu shows every library returned by Jellyfin and its latest items, including video, music, photo, and playlist libraries. Live TV gets a channel entry without a latest-items request. Items that mpv cannot render, such as ebooks, are ignored.

Use `home_latest_limit` in `jellyfin_client.conf` to control how many latest items are shown for each library on the root menu.

For TV libraries, latest episodes are deduplicated by parent series so selecting them enters the series episode list instead of playing one returned episode directly.

The original root-menu "Other" behavior is preserved: a library present in either `MyMediaExcludes` or `LatestItemsExcludes` is moved into the final "Other" group and no latest-items request is made for it. The group is hidden when empty.

Libraries and search results are paginated. Use `page_size` in `jellyfin_client.conf` to configure the page size. Episode lists load in full so selecting an episode can queue every following episode accurately.

Media items show watch-state prefixes: `🔲` unwatched, `🔄` partially watched, and `✅` watched. Series episode lists show unfinished episodes first by newest date-added time, followed by watched episodes in reverse episode order.

Video, audio, and audiobook items stream their original files directly and resume from Jellyfin's saved position when available. Audio plays only the selected track. Photos use Jellyfin's primary image endpoint and remain on screen as a single static image. Episodes selected from a series queue the selected episode and all following episodes in chronological order.

Live TV supports channel browsing and current-program titles. The script opens a Jellyfin live media source before playback and releases it on stop, channel change, or shutdown. Server encoding remains disabled; sources that mpv cannot decode directly fail instead of falling back to transcoding. Guide, scheduling, recording, and recording management are outside the scope.

Video, audio, and live playback report ordered state to Jellyfin. Video and audio update progress on pause and seek, while ordinary video also loads external text subtitles exposed by Jellyfin. Photos do not create playback sessions.

See `script-opts/jellyfin_client.conf` for all configuration options.

## Requirements

- mpv `0.39.0` or newer (using native `mp.input.select` menus)
- mpv native console and menu support through `mp.input.get` and `mp.input.select`
- `curl` available in PATH

Protocol behavior is verified by this repository's mock tests; no specific Jellyfin server-version compatibility is claimed without a real server environment.

## Development

Run the dependency-free mock test with a Lua 5.1-compatible runtime:

```text
lua tests/jellyfin_client_test.lua scripts/jellyfin_client.lua
```

The test drives the public mpv bindings and callbacks with mocked API responses. It covers Quick Connect, authentication reset, the Other group, multi-media browsing, latest-series deduplication, pagination, audio/video resume, photos, live-stream cleanup, ordered playback reporting, subtitles, multipart items, local-file isolation, and shutdown cleanup.
