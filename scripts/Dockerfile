# syntax=docker/dockerfile:1

FROM ubuntu:24.04 AS builder

ARG ODIN_RELEASE=dev-2026-09

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates clang curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir /opt/odin \
    && curl --fail --location --silent --show-error \
        "https://github.com/odin-lang/Odin/releases/download/${ODIN_RELEASE}/odin-linux-amd64-${ODIN_RELEASE}.tar.gz" \
        | tar --extract --gzip --strip-components=1 --directory /opt/odin

ENV PATH=/opt/odin:$PATH

WORKDIR /build

COPY src/common ./src/common
COPY src/server ./src/server

ARG YAP_VERSION=dev
ARG YAP_COMMIT=

RUN set -eux; \
    version=${YAP_VERSION#v}; \
    commit=$(printf %.7s "$YAP_COMMIT"); \
    mkdir -p bin; \
    odin build src/server \
        -collection:common=src/common \
        -vet \
        -strict-style \
        -o:size \
        -out:bin/yap-server \
        "-define:YAP_VERSION=\"${version}\"" \
        "-define:YAP_COMMIT=\"${commit}\""

FROM alpine:3.22

RUN apk add --no-cache gcompat \
    && addgroup -S yap \
    && adduser -S -G yap -h /nonexistent -s /sbin/nologin yap \
    && mkdir /data \
    && chown yap:yap /data

COPY --from=builder --chown=yap:yap /build/bin/yap-server /usr/local/bin/yap-server

USER yap
WORKDIR /app

VOLUME ["/data"]
EXPOSE 7777/udp

ENTRYPOINT ["/usr/local/bin/yap-server", "/data/config.json"]