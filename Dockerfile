FROM ghcr.io/lemker/uosserver:0.0.54-multiarch@sha256:c0b5dbe7b15494f904c84b17d5f8859ab1ee972874ec10fee5f23f8cb66b9131

LABEL org.opencontainers.image.source="https://github.com/matdew/unifi-os-server"

ENV UOS_SERVER_VERSION="5.0.6"

STOPSIGNAL SIGRTMIN+3

COPY uos-entrypoint.sh /root/uos-entrypoint.sh

RUN ["chmod", "+x", "/root/uos-entrypoint.sh"]
ENTRYPOINT ["/root/uos-entrypoint.sh"]
