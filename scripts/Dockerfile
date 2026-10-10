# syntax=docker/dockerfile:1

FROM ubuntu:24.04 AS builder

ARG ODIN_RELEASE=dev-2026-09

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates clang cmake curl make \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir /opt/odin \
    && curl --fail --location --silent --show-error \
        "https://github.com/odin-lang/Odin/releases/download/${ODIN_RELEASE}/odin-linux-amd64-${ODIN_RELEASE}.tar.gz" \
        | tar --extract --gzip --strip-components=1 --directory /opt/odin

ENV PATH=/opt/odin:$PATH

WORKDIR /build

COPY src/common ./src/common
COPY src/server ./src/server
COPY scripts/fetch-sqlite.sh scripts/sqlite.version \
    scripts/fetch-webp.sh scripts/build-webp.sh scripts/webp.version ./scripts/

# libwebp, for animated emoji (src/common/webp), and Odin's stb_image,
# which reads GIF emoji: a release doesn't always ship it built.
RUN set -eux; \
    CC=clang sh scripts/build-webp.sh; \
    [ -f /opt/odin/vendor/stb/lib/stb_image.a ] || make -C /opt/odin/vendor/stb/src

RUN set -eux; \
    . scripts/sqlite.version; \
    sh scripts/fetch-sqlite.sh .cache; \
    clang -Os -I".cache/sqlite-autoconf-${sqlite_version}" \
        -c src/server/sqlite/yap_sqlite.c \
        -o src/server/sqlite/yap_sqlite.o; \
    ar rcs src/server/sqlite/libyap_sqlite.a src/server/sqlite/yap_sqlite.o; \
    rm src/server/sqlite/yap_sqlite.o

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

FROM docker.io/emscripten/emsdk:latest AS web-builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/odin /opt/odin

ENV PATH=/opt/odin:$PATH

WORKDIR /build

COPY deps/thirdparty ./deps/thirdparty
COPY src/common ./src/common
COPY src/client ./src/client
COPY web ./web
COPY scripts/fetch-opus.sh scripts/opus.version scripts/version-defines.sh ./scripts/

RUN sh web/build.sh

# Alpine's gcompat does not provide the fcntl64 symbol emitted by the
# current Odin Linux toolchain, so the runtime needs glibc.
FROM ubuntu:24.04

# libcurl is loaded at runtime for the server's email, if configured;
# the certificates are for checking the mail server's.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libcurl4t64 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system yap \
    && useradd --system --gid yap --home-dir /nonexistent --shell /usr/sbin/nologin yap \
    && install --directory --owner yap --group yap /data

COPY --from=builder --chown=yap:yap /build/bin/yap-server /usr/local/bin/yap-server
COPY --from=web-builder --chown=yap:yap /build/web/out /app/web/out

USER yap
WORKDIR /app

VOLUME ["/data"]
EXPOSE 7777/udp
EXPOSE 8080/tcp

ENTRYPOINT ["/usr/local/bin/yap-server", "/data/config.json"]