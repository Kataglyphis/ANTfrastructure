ARG COPY_SOURCE
FROM docker.io/library/alpine:3.20
COPY --from=${COPY_SOURCE} /etc/alpine-release /tmp/alpine-release
RUN test -s /tmp/alpine-release
