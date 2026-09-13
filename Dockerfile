# Pickarr - AI-assisted release selector sidecar for Sonarr and Radarr.
# ---------------------------------------------------------------------------
# Build stage
# ---------------------------------------------------------------------------
FROM ocaml/opam:debian-12-ocaml-5.2 AS builder

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libev-dev libssl-dev libgmp-dev pkg-config m4 \
 && rm -rf /var/lib/apt/lists/*

USER opam
WORKDIR /home/opam/pickarr

# Dependencies first so they stay cached while the sources change.
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam *.opam ./
RUN opam update \
 && opam install . --deps-only --yes

COPY --chown=opam:opam lib ./lib
COPY --chown=opam:opam bin ./bin
COPY --chown=opam:opam test ./test

RUN opam exec -- dune build --release bin/main.exe

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM debian:12-slim

LABEL org.opencontainers.image.title="Pickarr" \
      org.opencontainers.image.description="AI-assisted release selector for Sonarr and Radarr" \
      org.opencontainers.image.source="https://github.com/lloyd-g-w/Pickarr"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libev4 libssl3 libgmp10 ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 1000 --create-home --shell /usr/sbin/nologin pickarr \
 && mkdir -p /data /app \
 && chown -R 1000:1000 /data /app \
 && chmod 755 /data

COPY --from=builder /home/opam/pickarr/_build/default/bin/main.exe /usr/local/bin/pickarr
COPY --chown=pickarr:pickarr static /app/static

ENV DATA_DIR=/data \
    STATIC_DIR=/app/static \
    HOST=0.0.0.0 \
    PORT=8484

USER pickarr
WORKDIR /app
VOLUME ["/data"]
EXPOSE 8484

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${PORT}/health || exit 1

ENTRYPOINT ["/usr/local/bin/pickarr"]
