# Raspberry Pi Host Setup

How to prepare a Raspberry Pi host for the audio client container: packages, memory tuning, reliability, and security. Several of the reliability measures address a failure mode observed in July 2026 on the Pi Zero 2 W (Wohnzimmer): an overnight Wi-Fi outage plus memory exhaustion led to swap thrashing on the SD card and a full system freeze that required a hard power cycle — and because the journal was not persistent, no system logs survived for diagnosis.

## Automated Setup

Everything below except the [manual steps](#manual-steps) is applied by the setup script in this repository, including installing Docker CE if it is missing.

```bash
sudo ./setup-pi.sh
sudo reboot   # if the script reports a reboot is needed
```

The script is idempotent — it skips anything already configured, so it is safe to re-run after changes or on an already-set-up Pi. The sections below document what it does and why; keep the script and this file in sync.

## Packages and Docker

The setup script installs Docker CE (engine + compose plugin) from Docker's official apt repository via the convenience script when `docker` is not yet present — equivalent to running manually:

```bash
curl -fsSL https://get.docker.com | sh
```

This is the supported path on Raspberry Pi OS (32-bit and 64-bit) and keeps Docker updated through apt afterwards. Use Docker CE, not Debian's `docker.io`: installing `docker.io` on a CE host makes apt silently remove `docker-ce`, so the script leaves existing installs untouched (it only warns if it finds `docker.io`).

The remaining host packages and the docker group:

```bash
sudo apt-get update
sudo apt-get install -y alsa-utils earlyoom unattended-upgrades
sudo usermod -aG docker "$USER"
```

Log out/in or reboot after changing group membership.

Verify host audio before testing the container (manual — needs ears):

```bash
aplay -l
speaker-test -t wav -c 2
getent group audio
```

Set `AUDIO_GID` in `.env` to the numeric GID from `getent group audio`; Raspberry Pi OS and Debian commonly use `29`.

## Memory

### GPU memory split

Headless Pis render nothing, but the firmware reserves 64 MB for the GPU by default — more than 10% of the RAM on a 512 MB board. Reclaim it in `/boot/firmware/config.txt`:

```ini
[all]
gpu_mem=16
```

Requires a reboot; verify with `vcgencmd get_mem gpu`.

### Swap and out-of-memory behavior

A large swapfile on an SD card is worse than useless on a small-RAM Pi: under memory pressure the system thrashes on slow storage for hours instead of OOM-killing the culprit, which presents as a total freeze. Keep swap small:

```bash
sudo swapoff /swapfile
sudo rm /swapfile
sudo fallocate -l 512M /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

(On stock Raspberry Pi OS with dphys-swapfile, set `CONF_SWAPSIZE=512` in `/etc/dphys-swapfile` instead.) If lots of swap is already in use, resize shortly after a reboot — `swapoff` has to pull everything back into RAM.

Additionally run `earlyoom`, which kills the largest process before the system becomes unresponsive and works even without memory cgroups:

```bash
sudo systemctl enable --now earlyoom
```

### Memory cgroups and container limits

Check `/proc/cmdline` for `cgroup_disable=memory`. With that flag, Docker memory limits are silently ignored and systemd-oomd cannot work. Remove the token from `/boot/firmware/cmdline.txt` (a single line — edit carefully) and reboot.

Then cap the container in `docker-compose.yml` so a leak cannot take down the host:

```yaml
services:
  audioclient:
    mem_limit: 256m
```

### Memory budget

On a 512 MB board, the audio stack plus dockerd leaves well under 200 MB of headroom. Avoid running additional heavy processes on the host — image builds, Node-based CLIs (including Claude Code, ~215 MB RSS), and similar tooling belong on another machine. Cross-build images as described in the README's buildx section.

## Reliability

### Persistent system logs

By default the journal may live in RAM only, so a crash leaves no evidence. Make it persistent with a size cap suitable for SD cards:

```bash
sudo mkdir -p /var/log/journal /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/persistent.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=64M
EOF
sudo systemctl restart systemd-journald
```

Verify after the next reboot that `journalctl --list-boots` shows more than one boot. Note: `Storage=auto` with an existing `/var/log/journal` directory *should* persist, but was observed not doing so — set `persistent` explicitly.

### Hardware watchdog

The Pi's SoC watchdog (`bcm2835_wdt`) can reboot the machine automatically when the kernel or PID 1 hangs, instead of requiring a physical power cycle:

```bash
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=15
EOF
sudo systemctl daemon-reexec
```

The BCM watchdog supports at most ~15 s, so don't set a larger value.

### Wi-Fi power save

Wi-Fi power management on the onboard `brcmfmac` chip is a common cause of overnight disconnects that make the Pi unreachable via SSH. Disable it:

```bash
sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF
sudo systemctl restart NetworkManager
```

Verify with `iw wlan0 get power_save` — it should report `off`. (Restarting NetworkManager briefly drops connectivity.)

### Docker log rotation and live-restore

A crash-looping or retry-flooding service can write hundreds of thousands of log lines per night; `live-restore` keeps containers running across dockerd restarts and upgrades. `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
```

Then `sudo systemctl restart docker`. Log options apply only to newly created containers, so recreate the stack afterwards: `docker compose up -d --force-recreate`.

## Security

### SSH: keys only

Key-based login should already be set up (the setup script refuses to disable password auth if `~/.ssh/authorized_keys` is missing). Then:

```bash
echo "PasswordAuthentication no" | sudo tee /etc/ssh/sshd_config.d/10-keys-only.conf
sudo systemctl reload ssh
```

Keep the current session open while testing a fresh key login. `PermitRootLogin` already defaults to `prohibit-password`.

### Automatic security updates

`unattended-upgrades` (installed above) needs to be switched on via `/etc/apt/apt.conf.d/20auto-upgrades`:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

The Debian default configuration then installs security updates automatically.

## Housekeeping

### Cloud-init

Images written with rpi-imager run cloud-init on every boot, which costs boot time on a slow SoC. Once provisioning is done:

```bash
sudo touch /etc/cloud/cloud-init.disabled
```

### Docker disk usage

Build cache and old images accumulate; on a small SD card this eventually fills the root filesystem. Occasionally run:

```bash
docker system df
docker builder prune
docker system prune
```

## Manual Steps

Things the script cannot do:

- **DHCP reservation** — pin the Pi's IP to its MAC address in the router (Fritz!Box: Heimnetz → Netzwerk → device details → "Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen"), so the snapserver, SSH config, and monitoring always find it.
- **Back up `.env`** — it is gitignored (correctly) and therefore the one piece of the setup that dies with the SD card. Keep a copy off-Pi; with the repo plus this document, a card failure becomes a reflash instead of archaeology.
- **Verify audio and set `AUDIO_GID`** — see [Packages and Docker](#packages-and-docker).
- **Monitor from another machine** — if you want to know when a Pi goes quiet, run the check elsewhere (e.g. a systemd timer or Uptime Kuma on the snapserver host). An agent on the Pi itself costs RAM and dies with the machine, exactly when it is needed.
