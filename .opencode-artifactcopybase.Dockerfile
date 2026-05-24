ARG ARTIFACT_IMAGE
ARG ARTIFACT_PLATFORM
ARG BASE_SOURCE_STAGE=base-image
FROM --platform=${ARTIFACT_PLATFORM} ${ARTIFACT_IMAGE} AS artifact-source
FROM docker.io/library/alpine:3.20 AS base-image
FROM scratch AS base-context
COPY --from=runtime_base /etc/alpine-release /alpine-release
FROM ${BASE_SOURCE_STAGE} AS final
COPY --from=artifact-source /etc/alpine-release /tmp/artifact-release
COPY --from=base-context /alpine-release /tmp/base-release
RUN test -s /tmp/artifact-release && test -s /tmp/base-release
