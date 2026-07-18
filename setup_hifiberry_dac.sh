#!/usr/bin/env bash
# Idempotent HiFiBerry GPIO DAC setup for the audio client stack.
# Documented in PI-SETUP.md — keep the two in sync.
#
# Usage: sudo ./setup_hifiberry_dac.sh [digital-volume-percent] [dtoverlay-name]
#   digital-volume-percent  hardware output ceiling, default 70
#   dtoverlay-name          only needed for boards without a HAT EEPROM,
#                           e.g. hifiberry-dac (DAC+ Zero, MiniAmp)
#
# The ceiling combines the -6 dB analogue stage (where the board has one)
# with the digital volume; day-to-day loudness stays in Snapcast, operating
# below this maximum.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

VOLUME="${1:-70}"
OVERLAY="${2:-}"
CARD=sndrpihifiberry

if ! [[ "$VOLUME" =~ ^[0-9]+$ ]] || [ "$VOLUME" -gt 100 ]; then
  echo "Volume must be an integer percentage 0-100" >&2
  exit 1
fi

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
  echo "    sudo $0 ${VOLUME} hifiberry-dac    # DAC+ Zero, MiniAmp" >&2
  echo "    sudo $0 ${VOLUME} hifiberry-dacplus" >&2
  exit 1
fi

log "Limiting DAC output ceiling: Digital ${VOLUME}%"
amixer -c "$CARD" sset Digital "${VOLUME}%" >/dev/null
if amixer -c "$CARD" sget Analogue >/dev/null 2>&1; then
  amixer -c "$CARD" sset Analogue 0% >/dev/null
  echo "    analogue stage set to -6 dB"
fi
amixer -c "$CARD" sget Digital | grep "Front Left:" | sed 's/^ */    /'

log "Persisting mixer state across reboots"
alsactl store

log "Done."
echo "    Point the stack at the card in .env: ALSA_SINK=plughw:CARD=${CARD},DEV=0"
echo "    then apply with: docker compose up -d"
