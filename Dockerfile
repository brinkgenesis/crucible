# syntax=docker/dockerfile:1.7
#
# Crucible multi-stage build.
#
#   1) elixir-builder  — compile deps, build a release
#   2) bridge-builder  — install bridge npm deps
#   3) runtime         — slim image with Elixir release + Node + bridge source
#
# The runtime image has Node available so the Elixir app can exec
# `node` against the bridge source for each SDK run.

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.2
ARG DEBIAN_VERSION=bookworm-20250113-slim
ARG NODE_VERSION=22

ARG ELIXIR_IMAGE=hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}
ARG RUNTIME_IMAGE=debian:${DEBIAN_VERSION}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Elixir release
# ─────────────────────────────────────────────────────────────────────────────
FROM ${ELIXIR_IMAGE} AS elixir-builder

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Deps first for layer caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config config
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

# Compile first — generates phoenix-colocated/<app> JS that the asset bundle imports.
RUN mix compile

# Phoenix assets pipeline (runs after compile so colocated hooks exist)
RUN mix assets.deploy

# Build the OTP release
RUN mix phx.gen.release \
 && mix release

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Bridge npm deps
# ─────────────────────────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-bookworm-slim AS bridge-builder

WORKDIR /bridge

COPY bridge/package.json bridge/package-lock.json* ./
# Production install — bridge is invoked as a subprocess, not a long-running
# service, so we don't bundle it. Source is copied straight through to runtime.
RUN npm ci --omit=dev || npm install --omit=dev

COPY bridge/src ./src
COPY bridge/tsconfig.json ./tsconfig.json

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: Runtime
# ─────────────────────────────────────────────────────────────────────────────
FROM ${RUNTIME_IMAGE} AS runtime

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates curl git \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen

# Install Node.js for the bridge subprocess
ARG NODE_VERSION=22
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4801

WORKDIR /app

# Non-root user
RUN groupadd -r crucible && useradd -r -g crucible -d /app crucible \
 && mkdir -p /app/.crucible \
 && chown -R crucible:crucible /app

# Elixir release
COPY --from=elixir-builder --chown=crucible:crucible /app/_build/prod/rel/crucible ./

# Bridge source + npm deps
COPY --from=bridge-builder --chown=crucible:crucible /bridge /app/bridge

# Workflow YAML templates (kept outside the release so users can override)
COPY --chown=crucible:crucible workflows /app/workflows

# Entrypoint runs migrations before starting the release
COPY --chown=crucible:crucible rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

USER crucible

EXPOSE 4801

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS http://localhost:${PORT}/api/health/live || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
