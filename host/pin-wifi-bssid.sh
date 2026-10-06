#!/usr/bin/env bash
# Pin wlan0 to one BSSID, so it stops roaming between the router's own radio and
# the repeater.
#
# Both observed brcmfmac firmware traps on these Pis landed in the same second
# as a roam, and since both APs share one SSID *and* one channel there is nothing
# to gain from roaming anyway -- the Pis are stationary. Pinning removes the
# trigger; the WiFi watchdog clears the pin on its own if the pinned AP ever
# disappears, so this cannot strand a headless box. Do not pin a host that has
# no watchdog installed.
#
#   pin-wifi-bssid                 pin to the best BSSID (see the caveat below)
#   pin-wifi-bssid AA:BB:..:FF     pin to a specific BSSID
#   pin-wifi-bssid --clear         remove the pin
#   pin-wifi-bssid --show          print the pin and the measured candidates
#
# **Scanning while associated is biased.** A single `nmcli device wifi list`
# tends to report the AP you are already on at full strength and its neighbours
# weakly or not at all, so picking the "strongest" from one scan mostly just
# re-picks the current AP -- which is the one we may be trying to leave. So the
# candidates are measured over several rescans, the best reading per BSSID wins,
# and switching away from the current AP additionally has to beat it by MARGIN.
# Treat an automatic choice as a suggestion: on a host where the router simply is
# not audible, the repeater is the right and only answer.
#
# Re-associating drops the link for a few seconds, so that step is handed to
# systemd rather than run inline: over SSH the disconnect would otherwise kill
# nmcli halfway through.
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
IFACE="${IFACE:-wlan0}"
SCANS="${SCANS:-4}"
MARGIN="${MARGIN:-5}"

profile="$(nmcli -t -f DEVICE,CONNECTION device 2>/dev/null | awk -F: -v d="${IFACE}" '$1 == d { print $2 }')"
if [ -z "${profile}" ] || [ "${profile}" = "--" ]; then
  profile="$(nmcli -t -f NAME,TYPE connection show | awk -F: '$2 == "802-11-wireless" { print $1; exit }')"
fi
[ -n "${profile}" ] || { echo "no wireless profile for ${IFACE}" >&2; exit 1; }

ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "${profile}" | cut -d: -f2-)"
current_pin="$(nmcli -t -f 802-11-wireless.bssid connection show "${profile}" | cut -d: -f2-)"
case "${current_pin}" in '--') current_pin="" ;; esac

# Best reading per BSSID across several rescans: "<bssid> <signal> <active>".
# nmcli -t escapes the colons inside a BSSID as "\:", so they are swapped for
# dashes while parsing and put back afterwards.
measure() {
  local i
  for i in $(seq 1 "${SCANS}"); do
    nmcli -t -f ACTIVE,BSSID,SSID,SIGNAL device wifi list --rescan yes 2>/dev/null \
      | sed 's/\\:/-/g' \
      | awk -F: -v s="${ssid}" '$3 == s { print $2, $4, $1 }'
    # Guarded with || true: on the last pass this test is false, and under
    # `set -e` with pipefail a false last command would fail the whole pipeline.
    if [ "${i}" -lt "${SCANS}" ]; then sleep 2; fi
  done | sort -k1,1 -k2,2nr | awk '!seen[$1]++ { gsub(/-/, ":", $1); print }'
}

active_bssid() {
  printf '%s\n' "$1" | awk '$3 == "yes" { print $1; exit }'
}

show() {
  local m
  m="$(measure)"
  echo "profile:     ${profile}"
  echo "ssid:        ${ssid}"
  echo "current pin: ${current_pin:---}"
  local a; a="$(active_bssid "${m}")"
  echo "associated:  ${a:---}"
  echo "candidates (best of ${SCANS} rescans):"
  printf '%s\n' "${m}" | awk '{ printf "   %-18s signal=%-4s%s\n", $1, $2, ($3 == "yes" ? " (associated)" : "") }'
}

reassociate() {
  echo "re-associating (link drops for a few seconds)..."
  systemd-run --unit=homophony-wifi-repin --collect --quiet \
    /usr/bin/nmcli connection up "${profile}" >/dev/null 2>&1 \
    || nmcli connection up "${profile}" >/dev/null 2>&1 || true
}

case "${1:---best}" in
  --show)
    show
    exit 0
    ;;
  --clear)
    nmcli connection modify "${profile}" 802-11-wireless.bssid ""
    echo "pin cleared on '${profile}' (was ${current_pin:---})"
    reassociate
    exit 0
    ;;
  --best|--strongest)
    meas="$(measure)"
    [ -n "${meas}" ] || { echo "no BSSID visible for SSID '${ssid}'" >&2; exit 1; }
    printf '%s\n' "${meas}" | awk '{ printf "candidate: %-18s signal=%-4s%s\n", $1, $2, ($3 == "yes" ? " (associated)" : "") }'

    best="$(printf '%s\n' "${meas}" | sort -k2,2nr | head -1 | awk '{ print $1 }')"
    best_sig="$(printf '%s\n' "${meas}" | sort -k2,2nr | head -1 | awk '{ print $2 }')"
    cur="$(active_bssid "${meas}")"
    cur_sig="$(printf '%s\n' "${meas}" | awk -v c="${cur}" '$1 == c { print $2; exit }')"

    target="${best}"
    if [ -n "${cur}" ] && [ "${best}" != "${cur}" ]; then
      if [ $(( best_sig - ${cur_sig:-0} )) -lt "${MARGIN}" ]; then
        echo "best ${best} (${best_sig}) does not beat the associated ${cur} (${cur_sig}) by ${MARGIN}; keeping ${cur}"
        target="${cur}"
      fi
    fi
    ;;
  *)
    target="$1"
    ;;
esac

if [ "${target}" = "${current_pin}" ]; then
  echo "'${profile}' is already pinned to ${target}; nothing to do"
  exit 0
fi

echo "pinning '${profile}' (${ssid}) to ${target}  [was ${current_pin:---}]"
nmcli connection modify "${profile}" 802-11-wireless.bssid "${target}"
reassociate
