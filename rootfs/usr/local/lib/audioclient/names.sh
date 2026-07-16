audioclient_room_name() {
  printf '%s' "${ROOM_NAME:-Room}"
}

audioclient_protocol_name() {
  printf '%s %s' "$(audioclient_room_name)" "$1"
}

audioclient_slug() {
  local value slug

  value="${1:-Room}"
  slug="$(printf '%s' "${value}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_.:-]/-/g; s/--*/-/g; s/^-//; s/-$//')"

  printf '%s' "${slug:-room}"
}

audioclient_multiroom_name() {
  printf '%s' "${MULTIROOM_NAME:-Multiroom}"
}

audioclient_multiroom_protocol_name() {
  printf '%s %s' "$(audioclient_multiroom_name)" "$1"
}

audioclient_snapserver_host() {
  if [ "${ENABLE_SNAPSERVER:-0}" = "1" ]; then
    printf '127.0.0.1'
  else
    printf '%s' "${SNAPSERVER:-snapserver.local}"
  fi
}

audioclient_snapclient_id() {
  if [ -n "${SNAPCLIENT_HOST_ID:-}" ]; then
    printf '%s' "${SNAPCLIENT_HOST_ID}"
    return
  fi

  printf 'audioclient-%s' "$(audioclient_slug "$(audioclient_protocol_name Snapclient)")"
}
