# syntax=docker/dockerfile:1
# Headless LLMMBC node image (docs/ARCHITECTURE.md §6, §8).
#
# Build from the repository root:
#   docker build -f docker/Dockerfile .
#   docker buildx build --platform linux/arm64 -f docker/Dockerfile .
#
# Stage 1 needs scripts/fetch_engine.sh (owned by the engine stream). Until that
# lands, the build stops at the guarded RUN below with an explicit message.

ARG DEBIAN_VERSION=bookworm-slim

# ---------------------------------------------------------------------------
# Stage 1: llama.cpp engine for the requested architecture.
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION} AS engine-builder
ARG TARGETARCH=amd64
ENV DEBIAN_FRONTEND=noninteractive \
    CMAKE_BUILD_PARALLEL_LEVEL=4
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      file \
      git \
      python3 \
      unzip \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN set -eux; \
    target="linux-x64"; \
    if [ "${TARGETARCH}" = "arm64" ]; then target="linux-arm64"; fi; \
    if [ ! -f scripts/fetch_engine.sh ]; then \
      echo "ERROR: scripts/fetch_engine.sh is missing (engine stream, docs/ARCHITECTURE.md §6)." >&2; \
      exit 1; \
    fi; \
    bash scripts/fetch_engine.sh "${target}" /out/engine; \
    test -x /out/engine/llama-server; \
    test -x /out/engine/rpc-server

# ---------------------------------------------------------------------------
# Stage 2: compile the headless node CLI.
# ---------------------------------------------------------------------------
FROM dart:stable AS cli-builder
WORKDIR /src/packages/llmmbc_core
COPY packages/llmmbc_core/pubspec.yaml ./
RUN dart pub get
COPY packages/llmmbc_core/ ./
RUN mkdir -p /out \
 && dart compile exe bin/llmmbc_node.dart -o /out/llmmbc_node

# ---------------------------------------------------------------------------
# Stage 3: minimal runtime image.
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      libcurl4 \
      libgomp1 \
      libstdc++6 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 llmmbc \
 && useradd --uid 10001 --gid 10001 --home-dir /data --no-create-home --shell /usr/sbin/nologin llmmbc \
 && install -d -o llmmbc -g llmmbc /data /opt/llmmbc/engine

COPY --from=cli-builder /out/llmmbc_node /usr/local/bin/llmmbc_node
COPY --from=engine-builder --chown=llmmbc:llmmbc /out/engine/ /opt/llmmbc/engine/
RUN chmod 0755 /usr/local/bin/llmmbc_node

ENV LLMMBC_ENGINE_DIR=/opt/llmmbc/engine \
    LLMMBC_DATA_DIR=/data

EXPOSE 47100/udp 47101 47102

USER llmmbc
WORKDIR /data

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:47101/v1/node || exit 1

ENTRYPOINT ["llmmbc_node"]
CMD ["serve"]
