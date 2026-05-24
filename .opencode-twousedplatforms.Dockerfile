ARG BASE_ONE
ARG PLATFORM_ONE
ARG BASE_TWO
ARG PLATFORM_TWO
FROM --platform=${PLATFORM_ONE} ${BASE_ONE} AS one
FROM --platform=${PLATFORM_TWO} ${BASE_TWO} AS two
FROM --platform=linux/arm64 docker.io/library/alpine:3.20
COPY --from=one /etc/os-release /tmp/one-os-release
COPY --from=two /etc/os-release /tmp/two-os-release
RUN test -s /tmp/one-os-release && test -s /tmp/two-os-release
