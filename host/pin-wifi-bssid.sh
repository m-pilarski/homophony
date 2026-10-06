#!/usr/bin/env bash
# Pin wlan0 to one BSSID, so it stops roaming between the router's own radio and
# the repeater.
#
# Both observed brcmfmac firmware traps on these Pis landed in the same second
# as a roam, and since both APs share one SSID *and* one channel there is nothing
# to gain from roaming anyway -- the Pis are stationary. Pinning removes the
# trigger; the WiFi watchdog clears the pin on its own if the pinned AP ever
# disappears, so this cannot strand a headless box.
#
#   pin-wifi-bssid.sh                 pin to the strongest visible BSSID
#   pin-wifi-bssid.sh AA:BB:..:FF     pin to a specific BSSID
#   pin-wifi-bssid.sh --clear         remove the pin
#   pin-wifi-bssid.sh --show          print the current pin and what is visible
#
# Re-associating drops the link for a few seconds, so that step is handed to
# systemd rather than run inline: over SSH the disconnect would otherwise kill
# nmcli halfway through.
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
IFACE="${IFACE:-wlan0}"

profile="$(nmcli -t -f DEVICE,CONNECTION device 2>/dev/null | awk -F: -v d="${IFACE}" '$1 == d { print $2 }')"
if [ -z "${profile}" ] || [ "${profile}" = "--" ]; then
  profile="$(nmcli -t -f NAME,TYPE connection show | awk -F: '$2 == "802-11-wireless" { print $1; exit }')"
fi
[ -n "${profile}" ] || { echo "no wireless profile for ${IFACE}" >&2; exit 1; }

ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "${profile}" | cut -d: -f2-)"
current="$(nmcli -t -f 802-11-wireless.bssid connection show "${profile}" | cut -d: -f2-)"

show() {
  echo "profile:     ${profile}"
  echo "ssid:        ${ssid}"
  echo "current pin: ${current:---}"
  echo "visible:"
  nmcli -f IN-USE,BSSID,SSID,CHAN,SIGNAL device wifi list --rescan auto 2>/dev/null \
    | awk -v s="${ssid}" 'NR == 1 || index($0, s)' | sed 's/^/  /'
}

reassociate() {
  echo "re-associating (link drops for a few seconds)..."
  systemd-run --unit=homophony-wifi-repin --collect --quiet \
    /usr/bin/nmcli connection up "${profile}" >/dev/null 2>&1 \
    || nmcli connection up "${profile}" >/dev/null 2>&1 || true
}

case "${1:---strongest}" in
  --show)
    show
    exit 0
    ;;
  --clear)
    nmcli connection modify "${profile}" 802-11-wireless.bssid ""
    echo "pin cleared on '${profile}' (was ${current:---})"
    reassociate
    exit 0
    ;;
  --strongest)
    # Strongest BSSID advertising our SSID. nmcli -t escapes the colons inside a
    # BSSID as "\:", so swap those for dashes, split the record on the real
    # field colons, then put the BSSID back together.
    target="$(nmcli -t -f BSSID,SSID,SIGNAL device wifi list --rescan yes 2>/dev/null \
      | sed 's/\\:/-/g' \
      | awk -F: -v s="${ssid}" '$2 == s { print $3, $1 }' \
      | sort -rn | head -1 | awk '{ print $2 }' | tr '-' ':')"
    [ -n "${target}" ] || { echo "no BSSID visible for SSID '${ssid}'" >&2; exit 1; }
    ;;
  *)
    target="$1"
    ;;
esac

echo "pinning '${profile}' (${ssid}) to ${target}  [was ${current:---}]"
nmcli connection modify "${profile}" 802-11-wireless.bssid "${target}"
reassociate
