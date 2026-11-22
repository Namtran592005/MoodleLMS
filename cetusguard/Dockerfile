FROM busybox:1.37.0-musl AS tools

FROM hectorm/cetusguard:v1

COPY --from=tools /bin/busybox /bin/busybox
