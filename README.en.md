# mpv-jellyfin usage

[简体中文](README.md) | [English](README.en.md)

## Install

Copy `scripts/jellyfin_client.lua` to your mpv `scripts` directory.

To customize options, copy `script-opts/jellyfin_client.conf` to your mpv `script-opts` directory. No configuration file is needed for the defaults; enter your server address on first use.

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

On first use, enter your server address, such as `https://jellyfin.example.com` or `http://192.168.1.40:8096/jellyfin`. If no saved token exists, the script starts Jellyfin Quick Connect. Select the displayed code to copy it to the system clipboard, then authorize it from another logged-in Jellyfin client. The server address, token, and stable device ID are saved in `~~state/jellyfin_auth.json`. If the code expires, reopen the menu to request a new one.

To change or correct the server address, exit mpv, delete `jellyfin_auth.json` from its state directory, then restart and enter the address and sign in again. Signing in after a token expires preserves the server address and device ID.

## Controls

- `Ctrl+j`: open or close the Jellyfin menu
- Native menu controls: use mpv's built-in select menu with keyboard, mouse, and filtering support
- `Ctrl+f`: search the Jellyfin server using mpv's built-in text input; if needed, sign in before the submitted search runs
- `Esc`: close the current menu

## Menu behavior

The root menu shows every library returned by Jellyfin and its latest items, including video, music, photo, and playlist libraries. Live TV gets a channel entry without a latest-items request. Items that mpv cannot render, such as ebooks, are ignored.

Use `home_latest_limit` in `jellyfin_client.conf` to control how many latest items are shown for each library on the root menu.

For TV libraries, latest episodes are deduplicated by parent series. Real series details are fetched in one batch and displayed in latest-content order. Series whose details cannot be retrieved are omitted while library entries remain available. Selecting a series opens its episode list.

Libraries present in either `MyMediaExcludes` or `LatestItemsExcludes` appear in the final "Other" group without latest items. The group is hidden when empty.

Libraries and search results are paginated. Use `page_size` in `jellyfin_client.conf` to configure the page size. Episode lists load in full so selecting an episode can queue every following episode accurately.

Media items show watch-state prefixes: `🔲` unwatched, `🔄` partially watched, and `✅` watched. Series episode lists show unfinished episodes first by newest date-added time, followed by watched episodes in reverse episode order.

Video, audio, and audiobook items stream their original files directly and resume from Jellyfin's saved position when available. Audio plays only the selected track. Photos use Jellyfin's primary image endpoint and remain on screen as a single static image. Episodes selected from a series queue the selected episode and all following episodes in chronological order.

Live TV supports channel browsing and current-program titles. The script opens a Jellyfin live media source before playback and releases it on stop, channel change, or shutdown. HTTP sources use static playback. Jellyfin receives UDP/RTP multicast and remuxes it into HTTP MPEG-TS using video and audio stream copy, without re-encoding or subtitle burn-in; mpv handles decoding. The Jellyfin server must have multicast network access, but mpv does not need it. Playback never falls back to re-encoding; sources that mpv cannot decode fail. Guide, scheduling, recording, and recording management are outside the scope.

Video, audio, and live playback report ordered state to Jellyfin. Multicast stream copy is reported as DirectStream; other playback is reported as DirectPlay. Video and audio update progress on pause and seek, while ordinary video also loads external text subtitles exposed by Jellyfin. Photos do not create playback sessions.

See `script-opts/jellyfin_client.conf` for all configuration options.

## Requirements

- mpv `0.39.0` or newer (using native `mp.input.select` menus)
- mpv native console and menu support through `mp.input.get` and `mp.input.select`
- `curl` available in PATH

## Development

To diagnose request failures, run `mpv --idle --log-file=mpv-jellyfin.log --msg-level=jellyfin_client=debug`. On Windows, use `mpv.exe` if needed. The log is written to the current directory and includes HTTP/curl status and error details.

Run the dependency-free mock test with a Lua 5.1-compatible runtime:

```text
lua tests/jellyfin_client_test.lua scripts/jellyfin_client.lua
```

The test drives the public mpv bindings and callbacks with mocked API responses. It covers Quick Connect, authentication reset, the Other group, multi-media browsing, latest-series deduplication, pagination, audio/video resume, photos, multicast stream copy, live-stream cleanup, ordered playback reporting, subtitles, multipart items, local-file isolation, and shutdown cleanup. It does not include integration testing with a real mpv/Jellyfin environment and does not establish server-version compatibility.
