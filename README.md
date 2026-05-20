# mpv-jellyfin usage

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

If no saved token exists, the script starts Jellyfin Quick Connect. Authorize the displayed code from another logged-in Jellyfin client. The token is saved in mpv's state directory.

## Controls

- `Ctrl+j`: open or close the Jellyfin menu
- Native menu controls: use mpv's built-in select menu with keyboard, mouse, and search support
- `Ctrl+f`: search, when `user-input-module` is installed

## Menu behavior

The root menu shows Jellyfin libraries and their latest items.

Use `home_latest_limit` in `jellyfin_client.conf` to control how many latest items are shown for each library on the root menu.

For TV libraries, latest episodes are shown as their parent series so selecting them enters the series episode list instead of playing a single returned episode directly.

Media items show watch-state prefixes: `🔲` unwatched, `🔄` partially watched, and `✅` watched. Series episode lists show unfinished episodes first by newest update time, followed by watched episodes in reverse episode order.

Selecting playable media starts playback in mpv and resumes from Jellyfin's saved playback position when available. When playing an episode from a series episode list, the script queues the selected episode and following playable items from that menu as an mpv playlist.

During playback, the script reports progress to Jellyfin, updates progress on pause and seek, and adds external subtitles when Jellyfin exposes them.

See `script-opts/jellyfin_client.conf` for all configuration options.

## Requirements

- mpv `0.38.0` or newer
- mpv native menu support through `mp.input.select`
- `curl` available in PATH
- optional: `user-input-module` for `Ctrl+f` search
