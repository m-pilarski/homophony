# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-container Raspberry Pi audio endpoint: PulseAudio + Snapcast client + optional Snapcast server + Spotify Connect (spotifyd) + UPnP renderer (upmpdcli + mpd), supervised by s6-overlay on Alpine. Everything is installed from Alpine packages (spotifyd comes from edge/community); nothing is built from source. There is no application code, test suite, or linter — the codebase is the Dockerfile, compose file, and bash scripts under `rootfs/`.

Note: `.env` is the live config for this host — don't overwrite it; it is gitignored, and `.env.example` is the template.

## Commands

```bash
docker compose pull   # compose.yml (default) runs the CI image from ghcr.io
docker compose up -d
docker compose logs -f
docker compose -f _compose.yml build   # local build variant
```

Validate a running container:

```bash
docker compose ps
docker logs audioclient --tail=200
docker exec -it audioclient pactl info
docker exec -it audioclient pactl list short sinks
docker exec -it audioclient pactl list short sink-inputs
```

Smoke test on a machine without audio hardware: set `ALSA_SINK=null` and `AUDIO_DEVICE=/dev/null` in `.env`. Caution on this host: **this stack's container is the production snapserver for the house** (it replaced the retired `audiostream` stack, whose files and `audiostream_data` volume are kept in `../audiostream` for rollback) — don't casually stop it, and run smoke tests in a separate compose project with moved ports (`SNAPSERVER_EXTRA_ARGS="--stream.port 11704 --tcp.port 11705 --http.port 11780"`, `SNAPCLIENT_EXTRA_ARGS="--port 11704"`, `SNAPSERVER_CONTROL_PORT=11705`) or the test client will join the real house server.

Cross-build for Pi from another host:

```bash
docker buildx build --platform linux/arm/v7,linux/arm64 -t local/audioclient:latest .
```

## Architecture

`rootfs/` is copied verbatim to `/` in the image. The s6-overlay layout:

- `rootfs/etc/cont-init.d/10-pulseaudio-config` — one-shot init that **generates all service config at container start** from env vars: `/etc/pulse/{client.conf,daemon.conf,default.pa}`, `/etc/mpd.conf`, `/etc/upmpdcli.conf`, `/etc/snapserver.conf`. To change any service's configuration, edit this script — there are no static config files.
- `rootfs/etc/services.d/*/run` — one long-running s6 service per process (pulseaudio, snapclient, snapclient-name, snapserver, spotifyd, mpd, upmpdcli, pulse-sink-watch, dbus, audio-priority), plus server-mode clones of the source services (spotifyd-multiroom, mpd-multiroom on 6601, upmpdcli-multiroom, dbus-multiroom) that feed the house stream. Must be executable; the Dockerfile chmods them.
- `rootfs/usr/local/lib/audioclient/names.sh` — sourced helpers that derive all advertised names (`${ROOM_NAME} Snapclient/Spotify/UPnP`, `${MULTIROOM_NAME} Spotify/UPnP`), the stable snapclient hostID from `ROOM_NAME`, and the snapclient's target host (`audioclient_snapserver_host`: `127.0.0.1` when `ENABLE_SNAPSERVER=1`, else `$SNAPSERVER`).

### Audio flow

All sources play into one shared PulseAudio daemon via a sink named `audio_output`. `ALSA_SINK` selects how that sink is created, with three modes handled in both `10-pulseaudio-config` and `pulse-sink-watch/run` (keep them in sync):

- explicit device (e.g. `plughw:CARD=Device,DEV=0`) → `module-alsa-sink`
- `null` → null sink (smoke tests)
- `auto` → `module-udev-detect`, no fixed default sink

With `DOWNMIX_TO_MONO=1` and an explicit device, the hardware sink is named `audio_output_hardware` and a mono `module-remap-sink` takes the `audio_output` name, so clients don't need to know about the downmix. Ignored for `auto`.

The UPnP path is indirect: upmpdcli controls a local MPD (127.0.0.1:6600) whose only output is PulseAudio (Alpine doesn't package gmrender).

Server mode (`ENABLE_SNAPSERVER=1`, one device per house): snapserver runs in the same container, fed by a `module-pipe-sink` named `snapcast` → FIFO `/run/snapserver/snapfifo` → snapserver `pipe://` source (s16le/48000/2ch on both ends — keep them matched). The local snapclient and snapclient-name then connect to `127.0.0.1`, ignoring `SNAPSERVER`; server state persists in `/var/lib/audioclient/snapserver`. The device stays a full room (local endpoints unchanged) and additionally advertises `${MULTIROOM_NAME} Spotify/UPnP` via the `*-multiroom` service clones, which are hard-routed into the `snapcast` sink and tag their pulse streams with `audioclient.domain=multiroom`. `pulse-sink-watch` deliberately never moves streams off the `snapcast` sink back to `audio_output`, and `audio-priority` arbitrates by domain (see above) so multiroom playback never mutes the local snapclient that plays it.

`audio-priority` enforces the source hierarchy UPnP > Spotify > Snapcast (`ENABLE_AUDIO_PRIORITY`, grace period `AUDIO_PRIORITY_GRACE_SECONDS`): it polls MPD's state for UPnP activity, detects Spotify by the `application.process.binary` property on sink-inputs (`pactl --format=json`), pauses spotifyd via MPRIS over a private session DBus (the `dbus` service; spotifyd runs with `--use-mpris`), and mutes — never pauses — the local snapclient sink-input so other Snapcast rooms keep playing. It arbitrates two independent domains: the room endpoints (mpd on 6600, untagged spotifyd streams; domain from `UPNP_DEVICE`/`SPOTIFYD_DEVICE` env, local by default) and, in server mode, the multiroom endpoints (mpd-multiroom on 6601, spotifyd streams tagged `audioclient.domain=multiroom` via `PULSE_PROP`, MPRIS on the second bus `DBUS_MULTIROOM_BUS_ADDRESS`). UPnP pauses Spotify within a domain, and only local-domain sources mute the local snapclient.

### Service script conventions

- Shebang is `#!/command/with-contenv bash` (s6 env injection) with `set -euo pipefail`.
- Disabled services (`ENABLE_*` != 1) `exec sleep infinity` instead of exiting, so s6 doesn't restart-loop them.
- Every audio client waits for the pulse socket plus a successful `pactl info` before `exec`ing the real process.
- `pulse-sink-watch` is the recovery loop for USB DACs that appear late or reconnect: it reloads the ALSA sink, re-creates the mono remap, resets the default sink, and moves orphaned sink-inputs back to `audio_output`. Related host-side piece: the compose file bind-mounts `/dev/snd` and allows char device major 116 (`device_cgroup_rules`) so new sound nodes stay visible without recreating the container.
- `snapclient-name` pushes the friendly name to the snapserver's JSON-RPC control port (1705) in an endless retry loop, since snapclient itself only sends a hostID.

### Runtime constraints

The container relies on host networking (mDNS/SSDP discovery for Spotify and UPnP breaks without it), the `/dev/snd` bind mount, and `group_add: ${AUDIO_GID}` matching the host's `audio` group.

The Dockerfile's final `RUN` greps spotifyd/snapclient/mpd help output to assert PulseAudio backend support — when bumping the Alpine version or packages, these checks catch packages built without pulse.
