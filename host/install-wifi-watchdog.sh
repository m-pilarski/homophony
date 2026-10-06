#!/usr/bin/env bash
# Install the WiFi watchdog on this host. For the Raspberry Pi endpoints, whose
# Broadcom SDIO WiFi traps and never recovers; the x86 server is on Ethernet.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0755 "${src}/homophony-wifi-watchdog" /usr/local/bin/homophony-wifi-watchdog
install -m 0755 "${src}/pin-wifi-bssid.sh"       /usr/local/bin/pin-wifi-bssid
install -m 0644 "${src}/homophony-wifi-watchdog.service" /etc/systemd/system/
install -m 0644 "${src}/homophony-wifi-watchdog.timer"   /etc/systemd/system/

if [ ! -e /etc/default/homophony-wifi-watchdog ]; then
  install -m 0644 "${src}/homophony-wifi-watchdog.default" /etc/default/homophony-wifi-watchdog
fi

systemctl daemon-reload
systemctl enable --now homophony-wifi-watchdog.timer

# One run now, so a broken install says so here rather than in an hour. The link
# is healthy at install time, so this does nothing but confirm detection works.
systemctl start homophony-wifi-watchdog.service || true

systemctl list-timers homophony-wifi-watchdog.timer --no-pager || true
journalctl -u homophony-wifi-watchdog.service -n 10 --no-pager || true
