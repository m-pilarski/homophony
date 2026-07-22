#!/usr/bin/env bash
# Idempotent Raspberry Pi host setup for the audio client stack.
# Documented in PI-SETUP.md — keep the two in sync.
#
# Usage: sudo ./setup_pi.sh [update-time]
#   update-time  HH:MM for the nightly container image update (default 05:00)
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

UPDATE_TIME="${1:-05:00}"
if ! [[ "$UPDATE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "Invalid update time '$UPDATE_TIME' — expected HH:MM (24h)" >&2
  exit 1
fi
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOOTDIR=/boot/firmware
[ -d "$BOOTDIR" ] || BOOTDIR=/boot
TARGET_USER="${SUDO_USER:-}"
REBOOT_NEEDED=0

log()  { echo "==> $*"; }
skip() { echo "    already configured: $*"; }

### Packages and Docker --------------------------------------------------

log "Installing packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  alsa-utils curl earlyoom unattended-upgrades

if command -v docker >/dev/null 2>&1; then
  skip "Docker ($(docker --version 2>/dev/null || echo present))"
  if dpkg -s docker.io >/dev/null 2>&1; then
    echo "    WARNING: Debian's docker.io is installed; PI-SETUP.md recommends Docker CE."
    echo "    Leaving it alone — never install docker.io and docker-ce side by side."
  fi
else
  log "Installing Docker CE from download.docker.com (includes compose plugin)"
  curl -fsSL https://get.docker.com | sh
fi

if [ -n "$TARGET_USER" ] && ! id -nG "$TARGET_USER" | grep -qw docker; then
  log "Adding $TARGET_USER to the docker group (log out/in to apply)"
  usermod -aG docker "$TARGET_USER"
else
  skip "docker group membership"
fi

### Memory ----------------------------------------------------------------

if grep -q "^gpu_mem=" "$BOOTDIR/config.txt"; then
  skip "gpu_mem in config.txt"
else
  log "Setting gpu_mem=16 in config.txt (headless: give RAM to Linux)"
  printf '\n[all]\n# Headless: minimal GPU memory split\ngpu_mem=16\n' >> "$BOOTDIR/config.txt"
  REBOOT_NEEDED=1
fi

if grep -q "cgroup_disable=memory" "$BOOTDIR/cmdline.txt"; then
  log "Removing cgroup_disable=memory from cmdline.txt (enables Docker memory limits)"
  cp "$BOOTDIR/cmdline.txt" "$BOOTDIR/cmdline.txt.bak"
  sed -i 's/ *cgroup_disable=memory//' "$BOOTDIR/cmdline.txt"
  REBOOT_NEEDED=1
else
  skip "memory cgroups enabled"
fi

# Large swap on an SD card thrashes for hours instead of OOM-killing; cap at 512M.
if [ -f /etc/dphys-swapfile ]; then
  if grep -q '^CONF_SWAPSIZE=512$' /etc/dphys-swapfile; then
    skip "dphys-swapfile size"
  else
    log "Capping dphys-swapfile at 512M"
    sed -i 's/^#\?CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
    dphys-swapfile swapoff
    dphys-swapfile setup
    dphys-swapfile swapon
  fi
elif [ -f /swapfile ]; then
  SWAP_MB=$(( $(stat -c%s /swapfile) / 1024 / 1024 ))
  if [ "$SWAP_MB" -le 640 ]; then
    skip "swapfile size (${SWAP_MB}M)"
  else
    AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    USED_SWAP_MB=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print int((t-f)/1024)}' /proc/meminfo)
    if [ "$USED_SWAP_MB" -lt "$AVAIL_MB" ]; then
      log "Recreating /swapfile at 512M (was ${SWAP_MB}M)"
      swapoff /swapfile
      rm /swapfile
      fallocate -l 512M /swapfile
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
    else
      echo "    WARNING: ${USED_SWAP_MB}M swap in use but only ${AVAIL_MB}M RAM available;"
      echo "    skipping swap resize — re-run shortly after a reboot."
    fi
  fi
fi

systemctl enable --now earlyoom

### Reliability -----------------------------------------------------------

if [ -f /etc/systemd/journald.conf.d/persistent.conf ]; then
  skip "persistent journal"
else
  log "Enabling persistent journal (capped at 64M)"
  mkdir -p /var/log/journal /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/persistent.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=64M
EOF
  systemctl restart systemd-journald
fi

if [ -f /etc/systemd/system.conf.d/watchdog.conf ]; then
  skip "hardware watchdog"
else
  log "Enabling hardware watchdog (15s)"
  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=15
EOF
  systemctl daemon-reexec
fi

if [ -f /etc/NetworkManager/conf.d/wifi-powersave-off.conf ]; then
  skip "Wi-Fi power save"
else
  log "Disabling Wi-Fi power save (connectivity blips for a moment)"
  mkdir -p /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF
  systemctl try-restart NetworkManager
fi

DOCKER_CHANGED=$(python3 - <<'EOF'
import json, os
path = "/etc/docker/daemon.json"
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
want = {
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"},
    "live-restore": True,
}
changed = False
for key, value in want.items():
    if cfg.get(key) != value:
        cfg[key] = value
        changed = True
if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
print("changed" if changed else "unchanged")
EOF
)
if [ "$DOCKER_CHANGED" = "changed" ]; then
  log "Configuring Docker log rotation and live-restore"
  systemctl restart docker
  echo "    NOTE: log options apply to new containers — run: docker compose up -d --force-recreate"
else
  skip "Docker daemon.json"
fi

### Auto-update -----------------------------------------------------------

desired_service="$(cat <<EOF
[Unit]
Description=Update audioclient container image
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${STACK_DIR}
ExecStart=/usr/bin/docker compose pull --quiet
ExecStart=/usr/bin/docker compose up -d
EOF
)"

desired_timer="$(cat <<EOF
[Unit]
Description=Nightly audioclient container image update

[Timer]
OnCalendar=*-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF
)"

units_changed=0
if [ "$(cat /etc/systemd/system/audioclient-update.service 2>/dev/null)" != "$desired_service" ]; then
  printf '%s\n' "$desired_service" > /etc/systemd/system/audioclient-update.service
  units_changed=1
fi
if [ "$(cat /etc/systemd/system/audioclient-update.timer 2>/dev/null)" != "$desired_timer" ]; then
  printf '%s\n' "$desired_timer" > /etc/systemd/system/audioclient-update.timer
  units_changed=1
fi

if [ "$units_changed" = "1" ]; then
  log "Configuring nightly image update at ${UPDATE_TIME} (±5 min)"
  systemctl daemon-reload
else
  skip "auto-update timer (${UPDATE_TIME})"
fi
systemctl enable --now --quiet audioclient-update.timer

### Security --------------------------------------------------------------

if [ -f /etc/ssh/sshd_config.d/10-keys-only.conf ]; then
  skip "SSH key-only login"
elif [ -n "$TARGET_USER" ] && [ -s "/home/$TARGET_USER/.ssh/authorized_keys" ]; then
  log "Disabling SSH password authentication"
  echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/10-keys-only.conf
  sshd -t
  systemctl reload ssh
else
  echo "    WARNING: no authorized_keys for '${TARGET_USER:-?}' — leaving SSH password auth enabled."
  echo "    Install a key (ssh-copy-id) and re-run."
fi

if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
  skip "automatic security updates"
else
  log "Enabling automatic security updates"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
fi

### Housekeeping ----------------------------------------------------------

if [ -d /etc/cloud ] && [ ! -f /etc/cloud/cloud-init.disabled ]; then
  log "Disabling cloud-init (provisioning done)"
  touch /etc/cloud/cloud-init.disabled
elif [ -d /etc/cloud ]; then
  skip "cloud-init disabled"
fi

### Summary ---------------------------------------------------------------

echo
log "Done."
if [ "$REBOOT_NEEDED" = "1" ]; then
  echo "    REBOOT REQUIRED to apply gpu_mem / cmdline changes: sudo reboot"
fi
echo "    Manual steps (see PI-SETUP.md): DHCP reservation in the router, back up .env,"
echo "    verify audio + AUDIO_GID, monitoring from another machine."
