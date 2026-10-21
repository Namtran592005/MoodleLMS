# Caddy co module rate_limit (github.com/mholt/caddy-ratelimit).
# Build 2 tang: tang builder tao binary, tang cuoi chi chua binary.
# Ghim ca phien ban Caddy va commit cua module de build lap lai duoc.
ARG CADDY_VERSION=2.11.7

FROM caddy:${CADDY_VERSION}-builder-alpine AS builder

ARG CADDY_VERSION
ARG CADDY_RATELIMIT_COMMIT=5625512f24f6f59d6f64fb3aafe5eecff0b286db

RUN xcaddy build "v${CADDY_VERSION}" \
    --with "github.com/mholt/caddy-ratelimit@${CADDY_RATELIMIT_COMMIT}"

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
