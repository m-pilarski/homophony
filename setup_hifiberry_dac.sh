#!/usr/bin/env bash
# Idempotent HiFiBerry GPIO DAC setup for the audio client stack.
# Documented in PI-SETUP.md — keep the two in sync.
#
# Usage: sudo ./setup_hifiberry_dac.sh [ceiling-db] [dtoverlay-name]
#   ceiling-db      hardware output ceiling in dB, default -18
#                   (0 = no attenuation, more negative = quieter)
#   dtoverlay-name  only needed for boards without a HAT EEPROM,
#                   e.g. hifiberry-dac (DAC+ Zero, MiniAmp)
#
# The ceiling is applied entirely in the digital volume with the analogue stage
# left at full (0 dB); day-to-day loudness stays in Snapcast, operating below
# this maximum. The PCM512x digital control is 0.5 dB per step, 0 dB at step 207.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

CEILING_DB="${1:--18}"
OVERLAY="${2:-}"
CARD=sndrpihifiberry

if ! [[ "$CEILING_DB" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] \
  || ! awk -v db="$CEILING_DB" 'BEGIN { exit !(db <= 0 && db >= -103.5) }'; then
  echo "Ceiling must be a dB value between -103.5 and 0 (e.g. -18)" >&2
  exit 1
fi
DIGITAL_STEP="$(awk -v db="$CEILING_DB" 'BEGIN { s = int(207 + db*2 + 0.5); if (s < 0) s = 0; if (s > 207) s = 207; print s }')"

BOOTDIR=/boot/firmware
[ -d "$BOOTDIR" ] || BOOTDIR=/boot

log()  { echo "==> $*"; }
skip() { echo "    already configured: $*"; }

card_present() { aplay -l 2>/dev/null | grep -q "^card [0-9]*: ${CARD}"; }

if card_present; then
  skip "HiFiBerry card present (${CARD})"
elif [ -n "$OVERLAY" ]; then
  if grep -q "^dtoverlay=${OVERLAY}" "$BOOTDIR/config.txt"; then
    skip "dtoverlay=${OVERLAY} in config.txt"
    echo "    Card still missing — check the HAT seating, then reboot." >&2
    exit 1
  fi
  log "Adding dtoverlay=${OVERLAY} to config.txt"
  printf '\n# HiFiBerry DAC\ndtoverlay=%s\n' "$OVERLAY" >> "$BOOTDIR/config.txt"
  echo "    REBOOT REQUIRED — then re-run this script to set the volume limit."
  exit 0
else
  echo "No HiFiBerry card found. Boards with a HAT EEPROM configure themselves —" >&2
  echo "check the seating and reboot. Boards without one need the overlay argument:" >&2
  echo "    sudo $0 ${CEILING_DB} hifiberry-dac    # DAC+ Zero, MiniAmp" >&2
  echo "    sudo $0 ${CEILING_DB} hifiberry-dacplus" >&2
  exit 1
fi

log "Limiting DAC output ceiling to ${CEILING_DB} dB (Digital step ${DIGITAL_STEP})"
if amixer -c "$CARD" sget Analogue >/dev/null 2>&1; then
  amixer -c "$CARD" sset Analogue 100% >/dev/null
  echo "    analogue stage set to 0 dB (full)"
fi
amixer -c "$CARD" sset Digital "$DIGITAL_STEP" >/dev/null
amixer -c "$CARD" sget Digital | grep "Front Left:" | sed 's/^ */    /'

log "Persisting mixer state across reboots"
alsactl store

log "Done."
echo "    Point the stack at the card in .env: ALSA_SINK=plughw:CARD=${CARD},DEV=0"
echo "    then apply with: docker compose up -d"
