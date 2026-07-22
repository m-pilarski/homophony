homophony_room_name() {
  printf '%s' "${ROOM_NAME:-Room}"
}

homophony_protocol_name() {
  printf '%s %s' "$(homophony_room_name)" "$1"
}

homophony_slug() {
  local value slug

  value="${1:-Room}"
  slug="$(printf '%s' "${value}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_.:-]/-/g; s/--*/-/g; s/^-//; s/-$//')"

  printf '%s' "${slug:-room}"
}

homophony_multiroom_name() {
  printf '%s' "${MULTIROOM_NAME:-Multiroom}"
}

homophony_multiroom_protocol_name() {
  printf '%s %s' "$(homophony_multiroom_name)" "$1"
}

homophony_snapserver_host() {
  if [ "${ENABLE_SNAPSERVER:-0}" = "1" ]; then
    printf '127.0.0.1'
  else
    printf '%s' "${SNAPSERVER:-snapserver.local}"
  fi
}

homophony_snapclient_id() {
  if [ -n "${SNAPCLIENT_HOST_ID:-}" ]; then
    printf '%s' "${SNAPCLIENT_HOST_ID}"
    return
  fi

  printf 'homophony-%s' "$(homophony_slug "$(homophony_protocol_name Snapclient)")"
}
