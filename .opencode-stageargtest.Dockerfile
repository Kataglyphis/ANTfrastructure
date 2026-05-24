ARG SOURCE_STAGE=first
FROM docker.io/library/alpine:3.20 AS first
RUN touch /first
FROM docker.io/library/alpine:3.20 AS second
RUN touch /second
FROM ${SOURCE_STAGE} AS final
RUN test -e /first || test -e /second
