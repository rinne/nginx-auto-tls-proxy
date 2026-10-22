# HTTP/3-capable curl for the smoke tests' QUIC assertions. Nothing from this
# image ships; it only exists so the tests can probe the proxy over HTTP/3 from
# a sidecar on the compose network.
#
# Alpine's curl package (and therefore the curl inside the image under test) is
# built without HTTP/3 as of curl 8.21, and host curl builds rarely have it
# either. Debian trixie's curl is built with it. The build asserts the feature
# so a future Debian change fails here, not as a silent false negative.
FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -V | grep -q HTTP3
CMD ["sleep", "infinity"]
