FROM alpine:3.22

ENV PULSE_RUNTIME_PATH=/tmp/pulse
ENV PULSE_SERVER=unix:/tmp/pulse/native
ENV XDG_RUNTIME_DIR=/tmp/runtime-audio
ENV ROOM_NAME=Room
ENV MULTIROOM_NAME=Multiroom
ENV SNAPSERVER=snapserver.local
ENV ALSA_SINK=default
ENV DOWNMIX_TO_MONO=0
ENV ENABLE_SNAPCLIENT=1
ENV ENABLE_SNAPSERVER=0
ENV ENABLE_SPOTIFY=1
ENV ENABLE_UPNP=1
ENV SPOTIFY_INITIAL_VOLUME=70
ENV SPOTIFY_USE_MPRIS=1
ENV ENABLE_AUDIO_PRIORITY=1
ENV AUDIO_PRIORITY_GRACE_SECONDS=10
ENV AUDIO_PRIORITY_RESUME_SPOTIFY=0
ENV DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus/session_bus_socket
ENV DBUS_MULTIROOM_BUS_ADDRESS=unix:path=/run/dbus/session_bus_socket_multiroom

RUN printf '@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community\n' >> /etc/apk/repositories \
  && apk add --no-cache \
    alsa-utils \
    alsa-plugins-pulse \
    bash \
    ca-certificates \
    dbus \
    jq \
    mpd \
    pulseaudio \
    pulseaudio-utils \
    s6-overlay \
    snapcast-client \
    snapcast-server \
    spotifyd@edgecommunity \
    upmpdcli

COPY rootfs/ /

RUN set -eux; \
    chmod +x /etc/cont-init.d/* /etc/services.d/*/run /usr/local/bin/homophony-healthcheck; \
    spotifyd --help 2>&1 | grep -Eiq 'pulseaudio'; \
    snapclient --help 2>&1 | grep -Eiq 'pulse'; \
    snapserver --version >/dev/null; \
    mpd --version 2>&1 | grep -Eiq '(^| )pulse( |$)'

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
  CMD ["/usr/local/bin/homophony-healthcheck"]

ENTRYPOINT ["/init"]
