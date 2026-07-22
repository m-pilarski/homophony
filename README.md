# Raspberry Pi Audio Client

Single-container Raspberry Pi audio endpoint with:

- PulseAudio mixer inside the container
- Snapcast client (`snapclient`)
- Optional Snapcast server (`snapserver`) so one device can act as the multiroom hub
- Spotify Connect receiver (`spotifyd`)
- UPnP renderer (`upmpdcli` + `mpd`)
- s6-overlay supervision

The container uses host networking and passes `/dev/snd` through from the Raspberry Pi host.
The image is based on Alpine and uses packaged runtime dependencies; it does not build audio services from source.

## Host Preparation

See [PI-SETUP.md](PI-SETUP.md) for preparing the Raspberry Pi host — `sudo ./setup_pi.sh` automates it (Docker CE, packages, memory tuning, reliability and security hardening, nightly image auto-update); the few remaining manual steps are listed there. For rooms with a HiFiBerry HAT, `sudo ./setup_hifiberry_dac.sh` configures the card and caps its output volume.

## Configure

```bash
cd stacks/audioclient
cp .env.example .env
nano .env
```

Important settings:

- `ROOM_NAME`: base name for advertised endpoints.
- `MULTIROOM_NAME`: base name for the house-wide endpoints the server device additionally advertises (see Snapcast Server).
- `SNAPSERVER`: Snapserver hostname or IP.
- `ALSA_SINK`: ALSA device passed to PulseAudio. Prefer a stable card name from `aplay -L`, for example `plughw:CARD=Device,DEV=0`, over a numeric card such as `plughw:1,0`.
- `DOWNMIX_TO_MONO`: set to `1` to downmix stereo sources to mono at the shared PulseAudio sink. This applies when `ALSA_SINK` is an explicit device; it is ignored with `ALSA_SINK=auto`.
- `AUDIO_DEVICE`: host sound device passed into the container, usually `/dev/snd`.
- `AUDIO_GID`: host audio group ID.
- `SPOTIFYD_DEVICE`: PulseAudio sink used by Spotify, usually `audio_output`.
- `UPNP_DEVICE`: PulseAudio sink used by the UPnP renderer's MPD. Empty (default) follows the default sink; set `snapcast` on the server device to make UPnP a multiroom source.
- `ENABLE_SNAPCLIENT`, `ENABLE_SPOTIFY`, `ENABLE_UPNP`: set to `0` to disable a service.
- `ENABLE_SNAPSERVER`: set to `1` on exactly one device to also run the Snapcast server there (see below). The device keeps working as a regular client.
- `ENABLE_AUDIO_PRIORITY`: set to `0` to allow all sources to play simultaneously (see below).
- `AUDIO_PRIORITY_GRACE_SECONDS`: how long a higher-priority source stays "active" after it stops playing (default `10`).
- `AUDIO_PRIORITY_RESUME_SPOTIFY`: set to `1` to automatically resume Spotify after the UPnP grace period, if it was paused by the priority service.

The visible endpoint names are generated from `ROOM_NAME`: `${ROOM_NAME} Snapclient`, `${ROOM_NAME} UPnP`, and `${ROOM_NAME} Spotify`.

For local smoke tests on machines without `/dev/snd`, set `ALSA_SINK=null` and `AUDIO_DEVICE=/dev/null`. For udev-based sink detection instead of an explicit ALSA device, set `ALSA_SINK=auto`.

## Build And Run

This repository includes a local `.env` for this non-Raspberry-Pi host:

- `ALSA_SINK=null`
- `AUDIO_DEVICE=/dev/null`
- `ENABLE_SNAPCLIENT=0`
- `ENABLE_SPOTIFY=0`
- `ENABLE_UPNP=1`

Those values let the container start without real audio hardware. For Raspberry Pi deployment, use `.env.example` as the template and set `AUDIO_DEVICE=/dev/snd`, `ALSA_SINK` to the desired output from `aplay -L`, and the services you want enabled.

USB audio devices can appear after Docker creates the container. This compose file bind-mounts `/dev/snd` and allows ALSA device major `116` so newly-created sound nodes stay visible after reconnects or card reordering. For explicit ALSA sinks, the container also keeps retrying `ALSA_SINK` and switches PulseAudio back to `audio_output` once the DAC is present.

On the Raspberry Pi, `compose.yml` (the default file) runs the multi-arch image published by CI to `ghcr.io/m-pilarski/audioclient`:

```bash
docker compose pull
docker compose up -d
docker compose logs -f
```

To build from source instead, use the build variant explicitly:

```bash
docker compose -f _compose.yml build
docker compose -f _compose.yml up -d
```

For cross-building from another host with buildx:

```bash
docker buildx build --platform linux/arm/v7,linux/arm64 -t local/audioclient:latest .
```

## Validate

```bash
docker compose ps
docker logs audioclient --tail=200
docker exec -it audioclient pactl info
docker exec -it audioclient pactl list short sinks
docker exec -it audioclient pactl list short sink-inputs
docker exec -it audioclient snapclient --list
```

Expected behavior:

- PulseAudio starts and keeps running.
- A real `audio_output` PulseAudio sink exists once the configured DAC is present.
- Snapserver shows a `${ROOM_NAME} Snapclient` client.
- Spotify shows a `${ROOM_NAME} Spotify` endpoint on the LAN.
- UPnP controllers show a `${ROOM_NAME} UPnP` renderer on the LAN.

The UPnP renderer is implemented with `upmpdcli` controlling a local MPD instance whose audio output is PulseAudio. This replaces `gmrender-resurrect` because Alpine does not package gmrender.

## Health And Auto-Recovery

The container ships a `HEALTHCHECK` that functionally probes every enabled service (PulseAudio responds, MPD answers its port, snapserver/upmpdcli hold their ports, Spotify/DBus are up), so `docker compose ps` shows `(healthy)` and `docker inspect --format '{{json .State.Health}}' audioclient` explains any failure. It intentionally stays healthy through self-healing transients — a USB DAC reconnecting, or the server briefly unreachable — so it does not trigger needless restarts.

Because Docker does not restart a container on health status alone, the compose file also runs a small `willfarrell/autoheal` companion (`audioclient-autoheal`) that restarts the container if it stays unhealthy. Tune with `AUTOHEAL_INTERVAL` / `AUTOHEAL_START_PERIOD` in `.env`. If the host already runs a global autoheal, this per-stack one is redundant but harmless; remove the `autoheal` service from the compose file to rely on the global one instead.

## Snapcast Server

Set `ENABLE_SNAPSERVER=1` on the one device that should act as the Snapcast server for the house. That is the only setting the server device needs: its own snapclient (and the name pusher) automatically connect to `127.0.0.1` instead of `SNAPSERVER`, so the device stays a normal room while serving the others. On every other device, point `SNAPSERVER` at the server host's IP or hostname.

With host networking the server exposes the standard Snapcast ports: `1704` (stream), `1705` (TCP JSON-RPC control), and `1780` (HTTP JSON-RPC, used by e.g. Home Assistant and the Android app). Alpine's package only ships a placeholder page instead of the Snapweb UI; to get the real web UI, bind-mount a [Snapweb](https://github.com/badaix/snapweb) build over `/usr/share/snapserver/snapweb`. Client names, volumes, and groups are persisted in the `data` volume under `/var/lib/audioclient/snapserver`.

The served audio comes from an extra PulseAudio sink named `snapcast` that only exists on the server device: everything played into it is encoded (FLAC, 48 kHz stereo) and distributed to all Snapcast clients, including the local one. Server mode automatically starts a second, house-wide set of source endpoints feeding this sink, next to the device's normal room endpoints:

- `${MULTIROOM_NAME} Spotify` (default `Multiroom Spotify`): a second Spotify Connect endpoint — playing to it reaches every room, while `${ROOM_NAME} Spotify` keeps playing only in this room.
- `${MULTIROOM_NAME} UPnP`: a second UPnP renderer (backed by its own MPD on `127.0.0.1:6601`) with the same split.

`MULTIROOM_SPOTIFY_INITIAL_VOLUME` (default `100`) sets the multiroom Spotify source gain; room loudness is set per client in Snapcast. Other ways into the house stream:

- Ad-hoc streaming from inside the container, e.g. `paplay --device=snapcast file.wav`.
- Extra Snapcast sources via `SNAPSERVER_EXTRA_ARGS`, e.g. `--stream.source "tcp://0.0.0.0:4953?name=line-in"`.
- `SPOTIFYD_DEVICE=snapcast` / `UPNP_DEVICE=snapcast` reroute the *room* endpoints themselves into the stream — rarely wanted now that dedicated multiroom endpoints exist.

Source priority arbitrates per domain: the multiroom endpoints pause each other (UPnP over Spotify) so they don't mix into the one shared stream, the room endpoints keep their usual local behavior, and multiroom playback never mutes the local snapclient — the server's own room hears the house stream like every other room.

## Source Priority

By default only one source is audible at a time, with the hierarchy UPnP > Spotify > Snapcast:

- When UPnP playback starts, Spotify is paused via MPRIS (position is kept; your Spotify app shows it paused).
- While UPnP or Spotify is playing, the local Snapcast stream is muted (never paused), so other Snapcast clients keep playing in sync and this room rejoins instantly when it is unmuted.
- A source must be silent for `AUDIO_PRIORITY_GRACE_SECONDS` (default 10) before lower-priority sources are allowed again, so short gaps between tracks don't let the lower source blare in.

Spotify is not auto-resumed after UPnP ends unless `AUDIO_PRIORITY_RESUME_SPOTIFY=1`; by default it just becomes startable again. Set `ENABLE_AUDIO_PRIORITY=0` to disable arbitration entirely.

## Troubleshooting

If no audio device appears inside the container:

```bash
ls -l /dev/snd
docker exec -it audioclient ls -l /dev/snd
getent group audio
```

If PulseAudio starts but exposes no useful sink, compare the host and container device lists:

```bash
aplay -L
docker exec -it audioclient aplay -L
```

Then set `ALSA_SINK` to a working output name, for example `plughw:CARD=Device,DEV=0`.

If discovery does not work, confirm the container is using host networking and that the controller device is on the same subnet/VLAN as the Pi.
