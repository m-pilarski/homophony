#!/usr/bin/env bash
# Install the USB DAC watchdog on this host. Raspberry Pi endpoints only -- the
# x86 server plays out of onboard analog and has no USB DAC to lose.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0755 "${src}/homophony-usb-dac-watchdog" /usr/local/bin/homophony-usb-dac-watchdog
install -m 0644 "${src}/homophony-usb-dac-watchdog.service" /etc/systemd/system/
install -m 0644 "${src}/homophony-usb-dac-watchdog.timer"   /etc/systemd/system/

# Config is the admin's to edit; never clobber an existing one.
if [ ! -e /etc/default/homophony-usb-dac-watchdog ]; then
  install -m 0644 "${src}/homophony-usb-dac-watchdog.default" /etc/default/homophony-usb-dac-watchdog
fi

systemctl daemon-reload
systemctl enable --now homophony-usb-dac-watchdog.timer

# One run now, so an install that cannot read the card or the .env says so here
# rather than silently doing nothing for a minute.
systemctl start homophony-usb-dac-watchdog.service || true

systemctl list-timers homophony-usb-dac-watchdog.timer --no-pager || true
journalctl -u homophony-usb-dac-watchdog.service -n 10 --no-pager || true
