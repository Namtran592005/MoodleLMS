# Build rieng chi de them module rate-limit.
FROM caddy:builder-alpine AS builder

RUN xcaddy build --with github.com/mholt/caddy-ratelimit

FROM caddy:alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
