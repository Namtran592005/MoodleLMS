# CetusGuard ships on a scratch image: no shell and no HTTP client.
# Add only a static busybox binary so Docker can probe /_ping.
# Use the musl variant: the default busybox binary is dynamically linked.

FROM busybox:1.37.0-musl AS tools

FROM hectorm/cetusguard:v1

COPY --from=tools /bin/busybox /bin/busybox
