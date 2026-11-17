FROM caddy:2.11-builder-alpine AS builder

RUN xcaddy build v2.11.9 --with github.com/mholt/caddy-ratelimit

FROM caddy:2.11-alpine

RUN apk add --no-cache tzdata

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
