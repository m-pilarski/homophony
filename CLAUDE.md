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
docker compose ps                                        # STATUS shows (healthy)
docker logs homophony --tail=200
docker inspect --format '{{json .State.Health}}' homophony | jq
docker exec -it homophony /usr/local/bin/homophony-healthcheck
docker exec -it homophony pactl info
docker exec -it homophony pactl list short sinks
docker exec -it homophony pactl list short sink-inputs
```

Smoke test on a machine without audio hardware: set `ALSA_SINK=null` and `AUDIO_DEVICE=/dev/null` in `.env`. Caution on this host: **this stack's container is the production snapserver for the house** (it replaced the retired `audiostream` stack, whose files and `audiostream_data` volume are kept in `../audiostream` for rollback) — don't casually stop it, and run smoke tests in a separate compose project with moved ports (`SNAPSERVER_EXTRA_ARGS="--stream.port 11704 --tcp.port 11705 --http.port 11780"`, `SNAPCLIENT_EXTRA_ARGS="--port 11704"`, `SNAPSERVER_CONTROL_PORT=11705`) or the test client will join the real house server.

Cross-build for Pi from another host:

```bash
docker buildx build --platform linux/arm/v7,linux/arm64 -t local/homophony:latest .
```

## Architecture

`rootfs/` is copied verbatim to `/` in the image. The s6-overlay layout:

- `rootfs/etc/cont-init.d/10-pulseaudio-config` — one-shot init that **generates all service config at container start** from env vars: `/etc/pulse/{client.conf,daemon.conf,default.pa}`, `/etc/mpd.conf`, `/etc/upmpdcli.conf`, `/etc/snapserver.conf`. To change any service's configuration, edit this script — there are no static config files.
- `rootfs/etc/services.d/*/run` — one long-running s6 service per process (pulseaudio, snapclient, snapclient-name, snapserver, spotifyd, mpd, upmpdcli, pulse-sink-watch, dbus, audio-priority, amp-trigger), plus server-mode clones of the source services (spotifyd-multiroom, mpd-multiroom on 6601, upmpdcli-multiroom, dbus-multiroom) that feed the house stream. Must be executable; the Dockerfile chmods them.
- `rootfs/usr/local/lib/homophony/names.sh` — sourced helpers that derive all advertised names (`${ROOM_NAME} Snapclient/Spotify/UPnP`, `${MULTIROOM_NAME} Spotify/UPnP`), the stable snapclient hostID from `ROOM_NAME`, and the snapclient's target host (`homophony_snapserver_host`: `127.0.0.1` when `ENABLE_SNAPSERVER=1`, else `$SNAPSERVER`).

### Audio flow

All sources play into one shared PulseAudio daemon via a sink named `audio_output`. `ALSA_SINK` selects how that sink is created, with three modes handled in both `10-pulseaudio-config` and `pulse-sink-watch/run` (keep them in sync):

- explicit device (e.g. `plughw:CARD=Device,DEV=0`) → `module-alsa-sink`
- `null` → null sink (smoke tests)
- `auto` → `module-udev-detect`, no fixed default sink

With `DOWNMIX_TO_MONO=1` and an explicit device, the hardware sink is named `audio_output_hardware` and a mono `module-remap-sink` takes the `audio_output` name, so clients don't need to know about the downmix. Ignored for `auto`.

The UPnP path is indirect: upmpdcli controls a local MPD (127.0.0.1:6600) whose only output is PulseAudio (Alpine doesn't package gmrender).

Server mode (`ENABLE_SNAPSERVER=1`, one device per house): snapserver runs in the same container, fed by a `module-pipe-sink` named `snapcast` → FIFO `/run/snapserver/snapfifo` → snapserver `pipe://` source (s16le/48000/2ch on both ends — keep them matched). The local snapclient and snapclient-name then connect to `127.0.0.1`, ignoring `SNAPSERVER`; server state persists in `/var/lib/homophony/snapserver`. The device stays a full room (local endpoints unchanged) and additionally advertises `${MULTIROOM_NAME} Spotify/UPnP` via the `*-multiroom` service clones, which are hard-routed into the `snapcast` sink and tag their pulse streams with `homophony.domain=multiroom`. `pulse-sink-watch` deliberately never moves streams off the `snapcast` sink back to `audio_output`, and `audio-priority` arbitrates by domain (see above) so multiroom playback never mutes the local snapclient that plays it.

`audio-priority` enforces the source hierarchy UPnP > Spotify > Snapcast (`ENABLE_AUDIO_PRIORITY`, grace period `AUDIO_PRIORITY_GRACE_SECONDS`): it polls MPD's state for UPnP activity, detects Spotify by the `application.process.binary` property on sink-inputs (`pactl --format=json`), pauses spotifyd via MPRIS over a private session DBus (the `dbus` service; spotifyd runs with `--use-mpris`), and mutes — never pauses — the local snapclient sink-input so other Snapcast rooms keep playing. It arbitrates two independent domains: the room endpoints (mpd on 6600, untagged spotifyd streams; domain from `UPNP_DEVICE`/`SPOTIFYD_DEVICE` env, local by default) and, in server mode, the multiroom endpoints (mpd-multiroom on 6601, spotifyd streams tagged `homophony.domain=multiroom` via `PULSE_PROP`, MPRIS on the second bus `DBUS_MULTIROOM_BUS_ADDRESS`). UPnP pauses Spotify within a domain, and only local-domain sources mute the local snapclient.

### Amplifier trigger (optional)

`amp-trigger` drives a GPIO line that switches a 12V trigger relay, so an external amp only powers up while the room is playing. Off unless `ENABLE_AMP_TRIGGER=1`, since it needs hardware wired to the pin. Level `1` always means "amp on" — `AMP_TRIGGER_ACTIVE_LOW=1` inverts the pin for relay boards that close on a low input, so nothing else in the script depends on board polarity.

Three things about it are easy to get wrong:

- **Playback is read from the sink state**, not from sink-inputs: PulseAudio holds a sink `RUNNING` only while it has an uncorked stream. It must be the sink clients play into (`AMP_TRIGGER_SINK`, default `audio_output`) — with `DOWNMIX_TO_MONO=1` that is the mono remap, while `audio_output_hardware` underneath stays `RUNNING` permanently and would pin the amp on forever.
- **A GPIO line is only held while a process holds it**, and on release the pin keeps its last driven value rather than reverting (verified on pinctrl-bcm2835). So one long-lived `gpioset` child holds the level, switching level means killing that child before starting the replacement, and the exit trap drives the line low *before* releasing it. Hardware that reverts to input instead also ends up off, since the relay needs an asserted pin to close.
- **Hysteresis is one-sided**: the pin goes high on the first poll that sees playback and only drops after a full `AMP_TRIGGER_IDLE_SECONDS` window with none, so gaps between tracks never cycle the relay.

GPIO access is opt-in through compose: `AMP_TRIGGER_DEVICE=/dev/gpiochip0:/dev/gpiochip0` under `devices:` (which also grants the cgroup permission for the chip's dynamic major), defaulting to a no-op `/dev/null:/dev/null` mapping so hosts without a relay are unaffected. Wired hosts so far: `.201`.

### Service script conventions

- Shebang is `#!/command/with-contenv bash` (s6 env injection) with `set -euo pipefail`.
- Disabled services (`ENABLE_*` != 1) `exec sleep infinity` instead of exiting, so s6 doesn't restart-loop them.
- Every audio client waits for the pulse socket plus a successful `pactl info` before `exec`ing the real process.
- `pulse-sink-watch` is the recovery loop for USB DACs that appear late or reconnect: it reloads the ALSA sink, re-creates the mono remap, resets the default sink, and moves orphaned sink-inputs back to `audio_output`. Related host-side piece: the compose file bind-mounts `/dev/snd` and allows char device major 116 (`device_cgroup_rules`) so new sound nodes stay visible without recreating the container.
- `snapclient-name` pushes the friendly name to the snapserver's JSON-RPC control port (1705) in an endless retry loop, since snapclient itself only sends a hostID.

### Health check

`rootfs/usr/local/bin/homophony-healthcheck` is the image `HEALTHCHECK` (30s interval, 25s timeout, 90s start-period, 3 retries). It probes each **enabled** service functionally, gated on the same `ENABLE_*` env the run scripts use.

Checks are either **hard** (broken now, and a restart clears it — reported immediately) or **soft** (things with their own recovery loop — reported only after failing continuously for `HEALTHCHECK_TOLERANCE_SECONDS`, default 600). Soft state is one file per check under `/run/homophony/health`, so a restart starts every window fresh and the failure that caused a restart cannot instantly re-trip it. A healthy run with a soft check mid-window prints `healthy (watching: …)`.

- hard: `pactl info`; a `nameserver` line in `/etc/resolv.conf`; s6 `up` for snapclient/spotifyd(-multiroom); the MPD greeting on 6600/6601; the DBus session-socket(s) when MPRIS is on; in server mode a real `Server.GetRPCVersion` JSON-RPC round trip on the control port.
- soft: the `audio_output` sink existing (skipped when `ALSA_SINK=auto`, which has no fixed sink); snapclient holding an established connection to its stream port; resolving `HEALTHCHECK_DNS_NAME` (defaults to a Spotify endpoint when Spotify is on, `none` skips it).

Two rules worth preserving when editing it. **Never probe a port by connecting to it** unless the connection is a real protocol exchange: a bare connect to snapserver's stream port registers as a client session and logs an error every interval, so LISTEN state is read out of `/proc/net/tcp` instead (snapserver's stream/http ports, upmpdcli's 49149/49150). And **keep the probe timeouts summing to less than the `HEALTHCHECK` timeout** — if Docker cuts the check short that counts as a failure and bypasses the tolerance windows entirely.

An empty `/etc/resolv.conf` is a hard failure because it is exactly what a container that started before the host's DNS was configured is left holding — it never repairs itself, a restart does fix it, and meanwhile snapcast keeps working (`SNAPSERVER` is usually an IP) while Spotify and UPnP are dead, which makes it very easy to miss.

The compose files add an `autoheal=true` label plus a `willfarrell/autoheal` companion container (Docker does not restart on health alone); keep both compose files in sync.

### Host-side USB DAC watchdog (Raspberry Pi endpoints)

`host/` is the one part of this repo that is **not** in the image: it installs onto the Pi hosts
themselves. It exists because a USB DAC that falls off the bus is a fault the container cannot reach.
When the hub disables the port (`usb usb1-port1: disabled by hub (EMI?)` → `USB disconnect` →
`attempt power cycle`) the card is gone from ALSA for the rest of the boot, `module-alsa-sink` can
never load, PulseAudio falls back to `auto_null`, and `pulse-sink-watch` has nothing to rebuild. No
container restart fixes it, so the autoheal restart that the health check eventually triggers just
loops. `/sys` is read-only in the container, so the port can only be driven from the host.

`homophony-usb-dac-watchdog` is a systemd timer (once a minute) that watches for the ALSA card named
by `ALSA_SINK` in `.env` — one source of truth, overridable via `CARD=` in
`/etc/default/homophony-usb-dac-watchdog` — and escalates only while it is missing:

1. after `RESET_AFTER` ticks, write `0` to the port's sysfs `disable` attribute, forcing a
   re-enumeration without touching the driver;
2. after `REBOOT_AFTER` ticks, reboot (`ALLOW_REBOOT=0` disables this).

**Never unbind/bind `dwc_otg`** to force re-enumeration on these Pis. The rebind path is broken:
`dwc_otg_driver_probe` fails and its error path calls `dwc_otg_driver_remove` on a half-initialised
device, which oopses the kernel and takes USB down completely until a reboot anyway.

Reboots are guarded three ways, and the third one matters most:

- `REBOOT_MIN_INTERVAL` (default 1h) — minimum spacing.
- `REBOOT_MAX` (default 2) consecutive reboots that failed to bring the card back, after which it
  only logs. This resets when the card is seen, so it bounds a DAC that is **gone for good**.
- `REBOOT_MAX_PER_WINDOW` (default 3) per `REBOOT_WINDOW` (default 24h), counted across the card
  coming and going and never reset by it. This is what bounds an **intermittent** DAC. `REBOOT_MAX`
  cannot: each reappearance clears it, leaving only `REBOOT_MIN_INTERVAL` between reboots — one an
  hour forever. A flaky DAC is intermittent by nature, so without this ceiling the watchdog turns a
  hardware fault into an indefinite hourly reboot cycle. Set it to `0` to disable rebooting entirely.

`DRY_RUN=1` logs the decisions and changes nothing.

Install with `sudo host/install-usb-dac-watchdog.sh` on a Pi. Not for the x86 server, which plays out
of onboard analog and has no USB DAC to lose. On `.201` the DAC is I2S rather than USB, so the port
re-enable is a no-op there and only the reboot fallback can apply.

The matching container-side piece is in the health check: the card named by `ALSA_SINK` missing is
reported as its own soft condition (`ALSA card X absent from the host`) rather than as
`no audio_output sink`, because the two want you looking in different places. Note `/proc/asound`
inside the container is the container's own procfs and never lists the host's cards — the card list
has to come through `/dev/snd`, which is what `aplay -l` reads.

### Runtime constraints

The container relies on host networking (mDNS/SSDP discovery for Spotify and UPnP breaks without it), the `/dev/snd` bind mount, and `group_add: ${AUDIO_GID}` matching the host's `audio` group.

The Dockerfile's final `RUN` greps spotifyd/snapclient/mpd help output to assert PulseAudio backend support — when bumping the Alpine version or packages, these checks catch packages built without pulse.
