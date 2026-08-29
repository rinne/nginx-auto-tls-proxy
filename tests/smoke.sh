#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/.tmp-smoke.XXXXXX")"
COMPOSE_FILE="$TMP_DIR/docker-compose.yaml"
HTTP_PORT="${HTTP_PORT:-18080}"
HTTPS_PORT="${HTTPS_PORT:-18443}"

if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose -f "$COMPOSE_FILE")
else
    COMPOSE=(docker compose -f "$COMPOSE_FILE")
fi

cleanup() {
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    if [[ -n "${STREAM_COMPOSE_FILE:-}" && -f "$STREAM_COMPOSE_FILE" ]]; then
        "${STREAM_COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/backend" "$TMP_DIR/custom" "$TMP_DIR/sites/default.local"
printf 'backend OK\n' > "$TMP_DIR/backend/index.html"
printf 'custom root OK\n' > "$TMP_DIR/custom/index.html"
printf 'rewrite landing OK\n' > "$TMP_DIR/sites/default.local/landing.html"

cat > "$COMPOSE_FILE" <<EOF
services:
  proxy:
    build:
      context: "$ROOT_DIR/nginx-auto-tls-proxy"
    ports:
      - "127.0.0.1:$HTTP_PORT:80"
      - "127.0.0.1:$HTTPS_PORT:443"
    volumes:
      - "$TMP_DIR/ssl:/ssl"
      - "$TMP_DIR/sites:/sites"
      - "$TMP_DIR/custom:/custom/custom.local"
    environment:
      STATIC_SITES: "default.local,custom.local,allowed.local,locked.local"
      STATIC_SITE_ROOTS: "custom.local:/custom/custom.local"
      PROXY_SITES: "proxy.local:http://backend/"
      SITE_ALIASES: "default.local:www.default.local"
      SITE_REDIRECTS: "shallow.local:default.local,deep.local:default.local:deep,explicit.local:default.local:no-deep"
      SITE_REWRITES: |
        default.local ^/code/([A-Z]{4}-[A-Z]{4})\$ /landing.html
      SITE_ALLOWED_IPS: "allowed.local:10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,[2001:db8::/32];locked.local:10.255.255.0/24,[2001:db8::/32]"
      LETSENCRYPT_EMAIL: ""
      CLIENT_MAX_BODY_SIZE: "16m"
      PROXY_READ_TIMEOUT: "60s"
      PROXY_SEND_TIMEOUT: "60s"
  backend:
    image: nginx:alpine
    volumes:
      - "$TMP_DIR/backend:/usr/share/nginx/html:ro"
EOF

"${COMPOSE[@]}" up -d --build

for _ in $(seq 1 30); do
    if "${COMPOSE[@]}" exec -T proxy /usr/local/bin/healthcheck.sh >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
"${COMPOSE[@]}" exec -T proxy /usr/local/bin/healthcheck.sh

"${COMPOSE[@]}" exec -T proxy sh -c \
    'mkdir -p /var/www/acme/.well-known/acme-challenge && printf challenge-ok > /var/www/acme/.well-known/acme-challenge/smoke-token'

redirect_headers="$(curl -ksS -D - -o /dev/null -H 'Host: default.local' "http://127.0.0.1:$HTTP_PORT/path")"
printf '%s\n' "$redirect_headers" | grep -q '^HTTP/1.1 302'
printf '%s\n' "$redirect_headers" | grep -q '^Location: https://default.local/path'

curl -fsS -H 'Host: default.local' \
    "http://127.0.0.1:$HTTP_PORT/.well-known/acme-challenge/smoke-token" \
    | grep -q 'challenge-ok'

curl -fksS --resolve "default.local:$HTTPS_PORT:127.0.0.1" \
    "https://default.local:$HTTPS_PORT/" \
    | grep -q 'Site: default.local'

curl -fksS --resolve "custom.local:$HTTPS_PORT:127.0.0.1" \
    "https://custom.local:$HTTPS_PORT/" \
    | grep -q 'custom root OK'

curl -fksS --resolve "proxy.local:$HTTPS_PORT:127.0.0.1" \
    "https://proxy.local:$HTTPS_PORT/" \
    | grep -q 'backend OK'

"${COMPOSE[@]}" exec -T proxy sh -c \
    "grep -q 'proxy_set_header Upgrade' /etc/nginx/conf.d/nginx-auto-tls-proxy-proxy.local.conf && grep -q 'proxy_set_header Connection' /etc/nginx/conf.d/nginx-auto-tls-proxy-proxy.local.conf"

"${COMPOSE[@]}" exec -T proxy sh -c \
    "grep -q 'resolver 127.0.0.11 valid=5s' /etc/nginx/conf.d/nginx-auto-tls-proxy-proxy.local.conf \
     && grep -q 'set \$upstream_proxy_local' /etc/nginx/conf.d/nginx-auto-tls-proxy-proxy.local.conf \
     && grep -q 'proxy_pass \$upstream_proxy_local\$request_uri' /etc/nginx/conf.d/nginx-auto-tls-proxy-proxy.local.conf"

# --- SITE_REWRITES coverage ---
# The generated config carries a quoted, internal `rewrite ... last;` line.
"${COMPOSE[@]}" exec -T proxy sh -c \
    'grep -q "rewrite \"\^/code/(\[A-Z\]{4}-\[A-Z\]{4})\$\" \"/landing.html\" last;" /etc/nginx/conf.d/nginx-auto-tls-proxy-default.local.conf' \
    || { printf 'FAIL: SITE_REWRITES did not emit the expected quoted rewrite line\n'; exit 1; }

# A matching public path is served internally: the client URL does NOT change
# (no 302) and the body of the rewrite target is returned with a 200.
rewrite_code="$(curl -ksS -o /dev/null -w '%{http_code}' \
    --resolve "default.local:$HTTPS_PORT:127.0.0.1" "https://default.local:$HTTPS_PORT/code/ASDF-YUIO")"
[[ "$rewrite_code" == "200" ]] \
    || { printf 'FAIL: internal rewrite returned %s, expected 200 (must not redirect)\n' "$rewrite_code"; exit 1; }
curl -fksS --resolve "default.local:$HTTPS_PORT:127.0.0.1" \
    "https://default.local:$HTTPS_PORT/code/ASDF-YUIO" \
    | grep -q 'rewrite landing OK' \
    || { printf 'FAIL: internal rewrite did not serve the target content\n'; exit 1; }

# A non-matching path is untouched by the rewrite (still served by the site).
curl -fksS --resolve "default.local:$HTTPS_PORT:127.0.0.1" \
    "https://default.local:$HTTPS_PORT/" \
    | grep -q 'Site: default.local' \
    || { printf 'FAIL: rewrite leaked onto non-matching paths\n'; exit 1; }

# --- SITE_REDIRECTS coverage ---
# Assert that a curl request returns 302 with the expected redirect_url. Uses
# curl's `-w '%{redirect_url}'` writeout, which is reliable across HTTP/1.1
# (Location:) and HTTP/2 (location:) without local header parsing.
assert_redirect() {
    local desc="$1" expected="$2"; shift 2
    local code redir
    code="$(curl -ksS -o /dev/null -w '%{http_code}'    "$@")"
    redir="$(curl -ksS -o /dev/null -w '%{redirect_url}' "$@")"
    [[ "$code" == "302" ]] \
        || { printf 'FAIL: %s status was %s, expected 302\n' "$desc" "$code"; exit 1; }
    [[ "$redir" == "$expected" ]] \
        || { printf 'FAIL: %s redirected to %q, expected %q\n' "$desc" "$redir" "$expected"; exit 1; }
}

# no-deep (default): HTTPS request on shallow.local/any/path -> root of destination.
assert_redirect 'HTTPS shallow.local (default no-deep)' \
    'https://default.local/' \
    --resolve "shallow.local:$HTTPS_PORT:127.0.0.1" "https://shallow.local:$HTTPS_PORT/some/path?q=1"

# Explicit :no-deep behaves the same as the default.
assert_redirect 'HTTPS explicit.local (explicit no-deep)' \
    'https://default.local/' \
    --resolve "explicit.local:$HTTPS_PORT:127.0.0.1" "https://explicit.local:$HTTPS_PORT/deep/path"

# deep: HTTPS request preserves $request_uri (path + query).
assert_redirect 'HTTPS deep.local (deep)' \
    'https://default.local/some/path?q=1' \
    --resolve "deep.local:$HTTPS_PORT:127.0.0.1" "https://deep.local:$HTTPS_PORT/some/path?q=1"

# HTTP-side single-hop: redirect goes directly to the final destination, NOT
# via https://<self>/ first. shallow.local on HTTP should land on
# https://default.local/ (no-deep) regardless of the request path.
assert_redirect 'HTTP shallow.local (single-hop no-deep)' \
    'https://default.local/' \
    -H 'Host: shallow.local' "http://127.0.0.1:$HTTP_PORT/some/path?q=1"

# HTTP-side single-hop deep mode.
assert_redirect 'HTTP deep.local (single-hop deep)' \
    'https://default.local/some/path?q=1' \
    -H 'Host: deep.local' "http://127.0.0.1:$HTTP_PORT/some/path?q=1"

# Redirect sources still serve ACME challenges on port 80 (so cert renewal works).
"${COMPOSE[@]}" exec -T proxy sh -c \
    'printf challenge-shallow > /var/www/acme/.well-known/acme-challenge/shallow-token'
curl -fsS -H 'Host: shallow.local' \
    "http://127.0.0.1:$HTTP_PORT/.well-known/acme-challenge/shallow-token" \
    | grep -q 'challenge-shallow' \
    || { printf 'FAIL: ACME challenge passthrough broken on redirect source shallow.local\n'; exit 1; }

# --- SITE_ALLOWED_IPS coverage ---
# The generated HTTPS block carries the allow/deny list; IPv6 brackets are
# stripped for nginx, and the HTTP (port 80) block stays open for ACME.
"${COMPOSE[@]}" exec -T proxy sh -c \
    'grep -q "allow 10.255.255.0/24;" /etc/nginx/conf.d/nginx-auto-tls-proxy-locked.local.conf \
     && grep -q "allow 2001:db8::/32;" /etc/nginx/conf.d/nginx-auto-tls-proxy-locked.local.conf \
     && grep -q "deny all;" /etc/nginx/conf.d/nginx-auto-tls-proxy-locked.local.conf' \
    || { printf 'FAIL: SITE_ALLOWED_IPS did not emit the expected allow/deny lines\n'; exit 1; }

# Backwards compatible: a site without an allow list gets no deny directive.
! "${COMPOSE[@]}" exec -T proxy sh -c \
    'grep -q "deny all;" /etc/nginx/conf.d/nginx-auto-tls-proxy-default.local.conf' \
    || { printf 'FAIL: a site without SITE_ALLOWED_IPS must not carry a deny rule\n'; exit 1; }

# The test client reaches nginx via the Docker bridge gateway (RFC1918), which
# allowed.local permits -> 200, and locked.local does not -> 403.
allowed_code="$(curl -ksS -o /dev/null -w '%{http_code}' \
    --resolve "allowed.local:$HTTPS_PORT:127.0.0.1" "https://allowed.local:$HTTPS_PORT/")"
[[ "$allowed_code" == "200" ]] \
    || { printf 'FAIL: allowed.local returned %s, expected 200 (client IP is in the allow list)\n' "$allowed_code"; exit 1; }

locked_code="$(curl -ksS -o /dev/null -w '%{http_code}' \
    --resolve "locked.local:$HTTPS_PORT:127.0.0.1" "https://locked.local:$HTTPS_PORT/")"
[[ "$locked_code" == "403" ]] \
    || { printf 'FAIL: locked.local returned %s, expected 403 (client IP not in the allow list)\n' "$locked_code"; exit 1; }

# Plain HTTP stays open on a locked site: ACME passthrough and the HTTP->HTTPS
# redirect must both still work (the allow list is HTTPS-only).
"${COMPOSE[@]}" exec -T proxy sh -c \
    'printf challenge-locked > /var/www/acme/.well-known/acme-challenge/locked-token'
curl -fsS -H 'Host: locked.local' \
    "http://127.0.0.1:$HTTP_PORT/.well-known/acme-challenge/locked-token" \
    | grep -q 'challenge-locked' \
    || { printf 'FAIL: ACME challenge passthrough broken on IP-locked locked.local\n'; exit 1; }
assert_redirect 'HTTP locked.local (open for redirect)' \
    'https://locked.local/some/path' \
    -H 'Host: locked.local' "http://127.0.0.1:$HTTP_PORT/some/path"

# Capture the built image ID before tearing down (compose state is lost after down).
PORT_IMG="$("${COMPOSE[@]}" images -q proxy 2>/dev/null | head -1)"

# Tear down the main stack before the negative-test substack, so we don't fight
# over container names / ports.
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true


# --- PROXY_STREAM_PATHS: live streaming behaviour (own compose substack) ---
# Run in a dedicated stack rather than the main one so the main stack keeps
# exercising the documented PROXY_READ_TIMEOUT default of 60s. Here the global
# is deliberately 2s while the stream path overrides to 30s, which makes the
# override provable in seconds instead of minutes.
STREAM_HTTPS_PORT="${STREAM_HTTPS_PORT:-18444}"
STREAM_COMPOSE_FILE="$TMP_DIR/docker-compose-stream.yaml"

mkdir -p "$TMP_DIR/sse" "$TMP_DIR/streamauth"

# SSE upstream: emits an event immediately, a second one after ~3s (a gap wider
# than the 2s global timeout), then holds the connection open with heartbeats.
# Every path is served identically, so the only difference between the streaming
# and non-streaming assertions below is the generated nginx config.
cat > "$TMP_DIR/sse/sse-server.py" <<'PYEOF'
import socket, threading, time

def handle(conn):
    try:
        conn.recv(65536)
        conn.sendall(b"HTTP/1.1 200 OK\r\n"
                     b"Content-Type: text/event-stream\r\n"
                     b"Cache-Control: no-cache\r\n"
                     b"Connection: close\r\n\r\n")
        conn.sendall(b"data: one\n\n")
        time.sleep(3)
        conn.sendall(b"data: two\n\n")
        while True:
            time.sleep(5)
            conn.sendall(b": ping\n\n")
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", 8080))
srv.listen(64)
while True:
    _c, _ = srv.accept()
    threading.Thread(target=handle, args=(_c,), daemon=True).start()
PYEOF

# htpasswd for the basic-auth stream site: streamuser / streampass (apr1).
printf 'streamuser:$apr1$smoke123$Y6/ZY5vxyJvtD3ITEgH1x.\n' > "$TMP_DIR/streamauth/htpasswd"
chmod -R a+rX "$TMP_DIR/sse" "$TMP_DIR/streamauth"

cat > "$STREAM_COMPOSE_FILE" <<EOF
services:
  proxy:
    build:
      context: "$ROOT_DIR/nginx-auto-tls-proxy"
    ports:
      - "127.0.0.1:$STREAM_HTTPS_PORT:443"
    volumes:
      - "$TMP_DIR/ssl-stream:/ssl"
      - "$TMP_DIR/streamauth:/auth:ro"
    environment:
      PROXY_SITES: "sse.local:http://sse-backend:8080/,authsse.local:http://sse-backend:8080/"
      BASIC_AUTH_FILES: "authsse.local:/auth/htpasswd"
      PROXY_STREAM_PATHS: "sse.local:/events:30s,authsse.local:/events:30s"
      PROXY_READ_TIMEOUT: "2s"
      PROXY_SEND_TIMEOUT: "60s"
      LETSENCRYPT_EMAIL: ""
  sse-backend:
    image: python:3-alpine
    volumes:
      - "$TMP_DIR/sse:/srv:ro"
    command: ["python3", "/srv/sse-server.py"]
EOF

# Its own compose project name: the streaming stack shares TMP_DIR with the main
# stack, and without this compose would derive the same project name and retag
# the proxy image, invalidating the image ID the DRY_RUN checks below reuse.
STREAM_PROJECT="$(basename "$TMP_DIR" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')stream"
if command -v docker-compose >/dev/null 2>&1; then
    STREAM_COMPOSE=(docker-compose -p "$STREAM_PROJECT" -f "$STREAM_COMPOSE_FILE")
else
    STREAM_COMPOSE=(docker compose -p "$STREAM_PROJECT" -f "$STREAM_COMPOSE_FILE")
fi

"${STREAM_COMPOSE[@]}" up -d --build

for _ in $(seq 1 30); do
    if "${STREAM_COMPOSE[@]}" exec -T proxy /usr/local/bin/healthcheck.sh >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
"${STREAM_COMPOSE[@]}" exec -T proxy /usr/local/bin/healthcheck.sh

# Read an SSE endpoint for at most N seconds and print whatever body arrived.
# curl exits 28 on our own cutoff; the partial body is still on stdout, which is
# exactly what we want to assert on.
sse_read() {
    local secs="$1"; shift
    curl -ksS -N --max-time "$secs" "$@" 2>/dev/null || true
}

# Same, but report how many seconds the transfer actually lasted. Used to prove
# who closed the connection: our cutoff, or nginx hitting proxy_read_timeout.
sse_elapsed() {
    local secs="$1"; shift
    local t0 t1
    t0="$(date +%s)"
    curl -ksS -N --max-time "$secs" "$@" >/dev/null 2>&1 || true
    t1="$(date +%s)"
    printf '%s' "$((t1 - t0))"
}

# 1. Unbuffered delivery. With nginx's default proxy_buffering on, NOTHING
#    reaches the client until the response ends — which for SSE is never — so
#    the arrival of the first event within 2s is the whole assertion. A config
#    grep alone would pass while the feature is broken.
body="$(sse_read 2 --resolve "sse.local:$STREAM_HTTPS_PORT:127.0.0.1" "https://sse.local:$STREAM_HTTPS_PORT/events")"
printf '%s\n' "$body" | grep -q 'data: one' \
    || { printf 'FAIL: streaming path buffered the response; nothing arrived within 2s. Got: %q\n' "$body"; exit 1; }

# 2. The per-path timeout overrides the global. The second event is emitted ~3s
#    in, well past the 2s PROXY_READ_TIMEOUT this stack runs with; it can only
#    arrive if the location's own 30s timeout took effect.
body="$(sse_read 5 --resolve "sse.local:$STREAM_HTTPS_PORT:127.0.0.1" "https://sse.local:$STREAM_HTTPS_PORT/events")"
printf '%s\n' "$body" | grep -q 'data: two' \
    || { printf 'FAIL: stream was cut before the 3s mark; per-path timeout did not override the 2s global. Got: %q\n' "$body"; exit 1; }

# 3. Negative — an unlisted path on the SAME host still buffers. At 1s the
#    global timeout has not fired yet, so with buffering on the client must
#    still have nothing.
body="$(sse_read 1 --resolve "sse.local:$STREAM_HTTPS_PORT:127.0.0.1" "https://sse.local:$STREAM_HTTPS_PORT/plain")"
printf '%s\n' "$body" | grep -q 'data: one' \
    && { printf 'FAIL: unlisted path delivered unbuffered; PROXY_STREAM_PATHS leaked beyond its prefix. Got: %q\n' "$body"; exit 1; }

# 4. Negative — the unlisted path still uses the 2s global timeout: nginx closes
#    it at ~2s, before the 3s event, so our 6s cutoff is never reached.
elapsed="$(sse_elapsed 6 --resolve "sse.local:$STREAM_HTTPS_PORT:127.0.0.1" "https://sse.local:$STREAM_HTTPS_PORT/plain")"
[[ "$elapsed" -lt 4 ]] \
    || { printf 'FAIL: unlisted path stayed open %ss; it should have been cut by the 2s global timeout\n' "$elapsed"; exit 1; }

# 5. Basic auth is NOT inherited by a location block, so the generated stream
#    location must carry auth_basic itself. Without this the feature would open
#    an unauthenticated hole in every site using BASIC_AUTH_FILES.
# The `|| true` matters: if auth_basic were missing the request would stream
# forever and curl would exit 28, killing the suite under `set -e` with an
# opaque timeout instead of naming the hole.
auth_code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 5 \
    --resolve "authsse.local:$STREAM_HTTPS_PORT:127.0.0.1" "https://authsse.local:$STREAM_HTTPS_PORT/events" 2>/dev/null || true)"
[[ "$auth_code" == "401" ]] \
    || { printf 'FAIL: stream path on a basic-auth site returned %q without credentials, expected 401 — auth_basic is missing from the stream location\n' "$auth_code"; exit 1; }

# Belt and braces: no stream content may reach an unauthenticated client.
body="$(sse_read 2 --resolve "authsse.local:$STREAM_HTTPS_PORT:127.0.0.1" "https://authsse.local:$STREAM_HTTPS_PORT/events")"
printf '%s\n' "$body" | grep -q 'data: one' \
    && { printf 'FAIL: unauthenticated client received stream content from a basic-auth site\n'; exit 1; }

# ...and with credentials it must actually stream (proving the 401 above comes
# from auth, not from a broken location).
body="$(sse_read 2 -u streamuser:streampass \
    --resolve "authsse.local:$STREAM_HTTPS_PORT:127.0.0.1" "https://authsse.local:$STREAM_HTTPS_PORT/events")"
printf '%s\n' "$body" | grep -q 'data: one' \
    || { printf 'FAIL: authenticated stream did not deliver; got: %q\n' "$body"; exit 1; }

# 6. Config shape, in the existing style, alongside the behavioural assertions.
"${STREAM_COMPOSE[@]}" exec -T proxy sh -c \
    'grep -q "location \^~ /events" /etc/nginx/conf.d/nginx-auto-tls-proxy-sse.local.conf \
     && grep -q "proxy_buffering                    off" /etc/nginx/conf.d/nginx-auto-tls-proxy-sse.local.conf \
     && grep -q "proxy_read_timeout                 30s" /etc/nginx/conf.d/nginx-auto-tls-proxy-sse.local.conf' \
    || { printf 'FAIL: PROXY_STREAM_PATHS did not emit the expected location/buffering/timeout lines\n'; exit 1; }

# 7. Drift pin. The proxy body is duplicated between `location /` and the stream
#    location on purpose (proxy_pass legitimately differs), so pin the part that
#    must NOT diverge: the forwarded header set.
"${STREAM_COMPOSE[@]}" exec -T proxy sh -c '
conf=/etc/nginx/conf.d/nginx-auto-tls-proxy-sse.local.conf
a=$(awk "/^    location \/ \{/,/^    \}/" "$conf" | grep proxy_set_header | sort)
b=$(awk "/^    location \^~ \/events \{/,/^    \}/" "$conf" | grep proxy_set_header | sort)
[ -n "$a" ] || { echo "FAIL: could not read location / headers"; exit 1; }
[ "$a" = "$b" ] || { echo "FAIL: proxy_set_header sets have drifted apart"; printf "%s\n---\n%s\n" "$a" "$b"; exit 1; }
' || exit 1

"${STREAM_COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

# --- HTTPS_PORT_OVERRIDE config generation (DRY_RUN) ---
port_check() {
    docker run --rm \
        -e STATIC_SITES="normal.local,alt.local" \
        -e PROXY_SITES="proxy.local:http://backend:3000/" \
        -e SITE_REDIRECTS="redir.local:alt.local" \
        -e HTTPS_PORT_OVERRIDE="alt.local:4444,proxy.local:5555,redir.local:6666" \
        -e DRY_RUN=1 \
        --entrypoint bash "$PORT_IMG" -c "$1"
}

port_check '
/entrypoint.sh >/dev/null 2>&1
grep -q "listen 443 ssl" /etc/nginx/conf.d/nginx-auto-tls-proxy-normal.local.conf \
    || { echo "FAIL: normal.local should listen on 443"; exit 1; }
grep -q "listen 4444 ssl" /etc/nginx/conf.d/nginx-auto-tls-proxy-alt.local.conf \
    || { echo "FAIL: alt.local should listen on 4444"; exit 1; }
grep -q "listen 5555 ssl" /etc/nginx/conf.d/nginx-auto-tls-proxy-proxy.local.conf \
    || { echo "FAIL: proxy.local should listen on 5555"; exit 1; }
grep -q "listen 6666 ssl" /etc/nginx/conf.d/nginx-auto-tls-proxy-redir.local.conf \
    || { echo "FAIL: redir.local should listen on 6666"; exit 1; }
grep -q "return 302 https://normal.local\$request_uri" /etc/nginx/conf.d/nginx-auto-tls-proxy-normal.local.conf \
    || { echo "FAIL: normal.local HTTP redirect should not include port"; exit 1; }
grep -q "return 302 https://alt.local:4444\$request_uri" /etc/nginx/conf.d/nginx-auto-tls-proxy-alt.local.conf \
    || { echo "FAIL: alt.local HTTP redirect should include :4444"; exit 1; }
grep -q "return 302 https://alt.local:4444/" /etc/nginx/conf.d/nginx-auto-tls-proxy-redir.local.conf \
    || { echo "FAIL: redir.local should redirect to alt.local:4444"; exit 1; }
grep -q "listen 443 ssl default_server" /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf \
    || { echo "FAIL: 443 default_server should exist when a site uses 443"; exit 1; }
! grep -q "listen 443 ssl" /etc/nginx/conf.d/nginx-auto-tls-proxy-alt.local.conf \
    || { echo "FAIL: alt.local should NOT listen on 443"; exit 1; }
'

# All sites on custom ports — no 443 catch-all.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e HTTPS_PORT_OVERRIDE="a.local:4444" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh >/dev/null 2>&1
! grep -q "listen 443" /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf \
    || { echo "FAIL: 443 catch-all should be omitted when no site uses 443"; exit 1; }
'

# --- SITE_REWRITES config generation & validation (DRY_RUN) ---
# Positive: a rule written against an ALIAS lands on the owner's server block,
# and the optional `break` flag is honored.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_ALIASES="a.local:www.a.local" \
    -e SITE_REWRITES=$'www.a.local ^/x$ /y.html break' \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh >/dev/null 2>&1
grep -q "rewrite \"\^/x\$\" \"/y.html\" break;" /etc/nginx/conf.d/nginx-auto-tls-proxy-a.local.conf \
    || { echo "FAIL: alias rewrite should land on owner block with break flag"; exit 1; }
'

# Negative: replacement without a leading slash (would become an external 302).
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_REWRITES=$'a.local ^/x$ http://evil.example/' \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected non-path replacement"; exit 1; }
true
' | grep -q 'replacement must be a path starting' \
    || { printf 'FAIL: should reject SITE_REWRITES replacement without leading slash\n'; exit 1; }

# Negative: rewrites are not allowed on proxy sites.
docker run --rm \
    -e PROXY_SITES="p.local:http://backend:3000/" \
    -e SITE_REWRITES=$'p.local ^/x$ /y' \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected rewrite on proxy site"; exit 1; }
true
' | grep -q 'only valid for static or static-php sites' \
    || { printf 'FAIL: should reject SITE_REWRITES on a proxy site\n'; exit 1; }

# Negative: rewrite host that is not a configured site/alias.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_REWRITES=$'nope.local ^/x$ /y' \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected unknown rewrite host"; exit 1; }
true
' | grep -q 'must be a configured site or alias' \
    || { printf 'FAIL: should reject SITE_REWRITES for an unknown host\n'; exit 1; }

# --- SITE_ALLOWED_IPS config generation & validation (DRY_RUN) ---
# Positive: a rule written against an ALIAS lands on the owner's HTTPS block,
# IPv6 brackets are stripped, and the list is closed with `deny all;`.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_ALIASES="a.local:www.a.local" \
    -e SITE_ALLOWED_IPS="www.a.local:10.1.2.0/24,[2001:db8::1]" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh >/dev/null 2>&1
grep -q "allow 10.1.2.0/24;" /etc/nginx/conf.d/nginx-auto-tls-proxy-a.local.conf \
    || { echo "FAIL: alias allow rule should land on owner block"; exit 1; }
grep -q "allow 2001:db8::1;" /etc/nginx/conf.d/nginx-auto-tls-proxy-a.local.conf \
    || { echo "FAIL: bracketed IPv6 should be emitted without brackets"; exit 1; }
grep -q "deny all;" /etc/nginx/conf.d/nginx-auto-tls-proxy-a.local.conf \
    || { echo "FAIL: allow list should be closed with deny all"; exit 1; }
'

# Negative: invalid IP/CIDR is rejected.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_ALLOWED_IPS="a.local:10.0.0.0/33" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected invalid CIDR"; exit 1; }
true
' | grep -q 'Invalid IP/CIDR in SITE_ALLOWED_IPS' \
    || { printf 'FAIL: should reject an out-of-range CIDR in SITE_ALLOWED_IPS\n'; exit 1; }

# Negative: unbracketed IPv6 is rejected (must be bracketed).
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_ALLOWED_IPS="a.local:2001:db8::1" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected unbracketed IPv6"; exit 1; }
true
' | grep -q 'Invalid IP/CIDR in SITE_ALLOWED_IPS' \
    || { printf 'FAIL: should reject unbracketed IPv6 in SITE_ALLOWED_IPS\n'; exit 1; }

# Negative: a group with no host:ip colon (e.g. a bare IP) is rejected.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_ALLOWED_IPS="10.0.0.1" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected a group without host:ip"; exit 1; }
true
' | grep -q 'Malformed SITE_ALLOWED_IPS group' \
    || { printf 'FAIL: should reject a group without a host:ip in SITE_ALLOWED_IPS\n'; exit 1; }

# Negative: a host group with an empty IP list is rejected.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_ALLOWED_IPS="a.local:" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected an empty IP list"; exit 1; }
true
' | grep -q 'has no IP addresses' \
    || { printf 'FAIL: should reject a host group with no IPs in SITE_ALLOWED_IPS\n'; exit 1; }

# Negative: unknown host is rejected.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e SITE_ALLOWED_IPS="nope.local:10.0.0.1" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected unknown host"; exit 1; }
true
' | grep -q 'must be a configured site or alias' \
    || { printf 'FAIL: should reject SITE_ALLOWED_IPS for an unknown host\n'; exit 1; }

# Negative: SITE_ALLOWED_IPS is not allowed on a TLS-terminator site.
docker run --rm \
    -e TLS_TERMINATOR_PROXY="s.local:4343:backend:8080" \
    -e SITE_ALLOWED_IPS="s.local:10.0.0.1" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected allow list on TLS-terminator"; exit 1; }
true
' | grep -q 'cannot be used with TLS_TERMINATOR_PROXY' \
    || { printf 'FAIL: should reject SITE_ALLOWED_IPS on a TLS_TERMINATOR_PROXY site\n'; exit 1; }

# --- TLS_TERMINATOR_PROXY config generation (DRY_RUN) ---
# Basic stream config: correct listen port, variable proxy_pass, HTTP ACME block, no HTTPS in conf.d
docker run --rm \
    -e STATIC_SITES="normal.local" \
    -e TLS_TERMINATOR_PROXY="stream.local:4343:backend:8080,stream2.local:5555:backend2:9090:proxy_protocol" \
    -e SITE_ALIASES="stream.local:www.stream.local" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh >/dev/null 2>&1
grep -q "listen 4343 ssl" /etc/nginx/stream.d/nginx-auto-tls-proxy-stream.local.conf \
    || { echo "FAIL: stream.local should listen on 4343 in stream.d"; exit 1; }
grep -q "proxy_pass \$backend_stream_local" /etc/nginx/stream.d/nginx-auto-tls-proxy-stream.local.conf \
    || { echo "FAIL: stream.local should use variable proxy_pass"; exit 1; }
grep -q "ssl_protocols" /etc/nginx/stream.d/nginx-auto-tls-proxy-stream.local.conf \
    || { echo "FAIL: stream config should include ssl_protocols"; exit 1; }
grep -q "listen 80" /etc/nginx/conf.d/nginx-auto-tls-proxy-stream.local.conf \
    || { echo "FAIL: stream.local should have HTTP block for ACME"; exit 1; }
grep -q "return 302 https://stream.local:4343\$request_uri" /etc/nginx/conf.d/nginx-auto-tls-proxy-stream.local.conf \
    || { echo "FAIL: stream.local HTTP redirect should include :4343"; exit 1; }
grep -q "server_name stream.local www.stream.local" /etc/nginx/conf.d/nginx-auto-tls-proxy-stream.local.conf \
    || { echo "FAIL: stream.local HTTP block should include alias"; exit 1; }
! grep -q "listen 4343 ssl" /etc/nginx/conf.d/nginx-auto-tls-proxy-stream.local.conf \
    || { echo "FAIL: stream.local should NOT have HTTPS block in conf.d"; exit 1; }
grep -q "proxy_protocol on" /etc/nginx/stream.d/nginx-auto-tls-proxy-stream2.local.conf \
    || { echo "FAIL: stream2.local should have proxy_protocol on"; exit 1; }
'

# Duplicate stream port rejection
docker run --rm \
    -e TLS_TERMINATOR_PROXY="a.local:4343:b1:80,b.local:4343:b2:80" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected duplicate stream ports"; exit 1; }
true
' | grep -q 'stream cannot share ports via SNI' \
    || { printf 'FAIL: should reject duplicate stream ports\n'; exit 1; }

# Port conflict with HTTPS_PORT_OVERRIDE
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e HTTPS_PORT_OVERRIDE="a.local:4444" \
    -e TLS_TERMINATOR_PROXY="b.local:4444:bg:80" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected conflicting ports"; exit 1; }
true
' | grep -q 'conflicts with HTTPS_PORT_OVERRIDE' \
    || { printf 'FAIL: should reject stream port conflicting with HTTPS_PORT_OVERRIDE\n'; exit 1; }


# --- PROXY_STREAM_PATHS config generation & validation (DRY_RUN) ---
# Positive: an entry written against an ALIAS lands on the owner's block, the
# timeout defaults to 10m, basic auth is repeated into the stream location, and
# the server-scope allow list still covers it.
docker run --rm \
    -e PROXY_SITES="p.local:http://backend:3000/" \
    -e SITE_ALIASES="p.local:www.p.local" \
    -e BASIC_AUTH_FILES="p.local:/run/secrets/x.htpasswd" \
    -e SITE_ALLOWED_IPS="p.local:10.0.0.0/8" \
    -e PROXY_STREAM_PATHS="www.p.local:/events" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh >/dev/null 2>&1
conf=/etc/nginx/conf.d/nginx-auto-tls-proxy-p.local.conf
grep -q "location \^~ /events" "$conf" \
    || { echo "FAIL: alias-targeted stream path should land on the owner block"; exit 1; }
grep -q "proxy_read_timeout                 10m" "$conf" \
    || { echo "FAIL: stream timeout should default to 10m"; exit 1; }
[ "$(grep -c "auth_basic_user_file" "$conf")" = "2" ] \
    || { echo "FAIL: auth_basic must be repeated in the stream location"; exit 1; }
grep -q "proxy_cache                        off" "$conf" \
    || { echo "FAIL: stream location should disable proxy_cache"; exit 1; }
grep -q "gzip                               off" "$conf" \
    || { echo "FAIL: stream location should disable gzip"; exit 1; }
'

# Byte-shape guarantee: with the variable unset, nothing about the generated
# config changes. This is the cheap permanent guard that mainstream output is
# untouched by the feature existing.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e PROXY_SITES="p.local:http://backend:3000/" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh >/dev/null 2>&1
! grep -rq "proxy_buffering" /etc/nginx/conf.d/ \
    || { echo "FAIL: proxy_buffering emitted without PROXY_STREAM_PATHS"; exit 1; }
! grep -rq "location \^~" /etc/nginx/conf.d/ \
    || { echo "FAIL: prefix location emitted without PROXY_STREAM_PATHS"; exit 1; }
'

# Negative: only proxy sites may carry stream paths.
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e PROXY_STREAM_PATHS="a.local:/events" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected stream path on a static site"; exit 1; }
true
' | grep -q 'only valid for PROXY_SITES' \
    || { printf 'FAIL: should reject PROXY_STREAM_PATHS on a static site\n'; exit 1; }

# Negative: TLS-terminator sites have no HTTP layer at all.
docker run --rm \
    -e TLS_TERMINATOR_PROXY="s.local:4343:backend:8080" \
    -e PROXY_STREAM_PATHS="s.local:/events" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected stream path on TLS-terminator"; exit 1; }
true
' | grep -q 'only valid for PROXY_SITES' \
    || { printf 'FAIL: should reject PROXY_STREAM_PATHS on a TLS_TERMINATOR_PROXY site\n'; exit 1; }

# Negative: unknown host.
docker run --rm \
    -e PROXY_SITES="p.local:http://backend:3000/" \
    -e PROXY_STREAM_PATHS="nope.local:/events" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected unknown host"; exit 1; }
true
' | grep -q 'must be a configured site or alias' \
    || { printf 'FAIL: should reject PROXY_STREAM_PATHS for an unknown host\n'; exit 1; }

# Negative: "/" collides with location / and nginx would refuse to start.
docker run --rm \
    -e PROXY_SITES="p.local:http://backend:3000/" \
    -e PROXY_STREAM_PATHS="p.local:/" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected / as a stream path"; exit 1; }
true
' | grep -q "must be more specific than '/'" \
    || { printf 'FAIL: should reject / as a PROXY_STREAM_PATHS path\n'; exit 1; }

# Negative: two entries for the same prefix on one server block.
docker run --rm \
    -e PROXY_SITES="p.local:http://backend:3000/" \
    -e SITE_ALIASES="p.local:www.p.local" \
    -e PROXY_STREAM_PATHS="p.local:/events,www.p.local:/events" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected duplicate stream paths"; exit 1; }
true
' | grep -q 'Duplicate PROXY_STREAM_PATHS path' \
    || { printf 'FAIL: should reject duplicate PROXY_STREAM_PATHS prefixes on one site\n'; exit 1; }

# Negative: malformed timeout.
docker run --rm \
    -e PROXY_SITES="p.local:http://backend:3000/" \
    -e PROXY_STREAM_PATHS="p.local:/events:5x" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected a bad timeout"; exit 1; }
true
' | grep -q 'timeout must look like' \
    || { printf 'FAIL: should reject a malformed PROXY_STREAM_PATHS timeout\n'; exit 1; }

# Negative: PROXY_RESOLVER=default with a path-carrying upstream cannot be
# reproduced inside a prefix location, so it is refused rather than mis-routed.
docker run --rm \
    -e PROXY_SITES="p.local:http://backend:3000/api/" \
    -e PROXY_RESOLVER=default \
    -e PROXY_STREAM_PATHS="p.local:/events" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh 2>&1 && { echo "FAIL: should have rejected default resolver + path upstream"; exit 1; }
true
' | grep -q 'needs a resolver' \
    || { printf 'FAIL: should reject PROXY_STREAM_PATHS with PROXY_RESOLVER=default and a path-carrying upstream\n'; exit 1; }

# Positive counterpart: the same resolver mode with a root upstream is fine and
# emits a URI-less proxy_pass, which forwards the client URI untouched.
docker run --rm \
    -e PROXY_SITES="p.local:http://backend:3000/" \
    -e PROXY_RESOLVER=default \
    -e PROXY_STREAM_PATHS="p.local:/events" \
    -e DRY_RUN=1 \
    --entrypoint bash "$PORT_IMG" -c '
/entrypoint.sh >/dev/null 2>&1
conf=/etc/nginx/conf.d/nginx-auto-tls-proxy-p.local.conf
awk "/^    location \^~ \/events \{/,/^    \}/" "$conf" | grep -q "proxy_pass http://backend:3000;" \
    || { echo "FAIL: resolver-less stream location should use a URI-less proxy_pass"; exit 1; }
'

# --- Negative: plain image must reject STATIC_PHP_SITES with a clear error. ---
NEG_COMPOSE_FILE="$TMP_DIR/docker-compose-php-negative.yaml"
cat > "$NEG_COMPOSE_FILE" <<EOF
services:
  proxy:
    build:
      context: "$ROOT_DIR/nginx-auto-tls-proxy"
    environment:
      STATIC_PHP_SITES: "must-fail.local"
      LETSENCRYPT_EMAIL: ""
EOF

if command -v docker-compose >/dev/null 2>&1; then
    NEG_COMPOSE=(docker-compose -f "$NEG_COMPOSE_FILE")
else
    NEG_COMPOSE=(docker compose -f "$NEG_COMPOSE_FILE")
fi

# `up` is expected to fail because the container exits with non-zero. Capture
# logs and grep for the documented "use the <ver>-php tag" message.
"${NEG_COMPOSE[@]}" up --abort-on-container-exit --exit-code-from proxy >/dev/null 2>&1 || true
neg_logs="$("${NEG_COMPOSE[@]}" logs --no-color 2>&1 || true)"
"${NEG_COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
printf '%s\n' "$neg_logs" | grep -q 'STATIC_PHP_SITES is set but this image was built without PHP support' \
    || { printf 'negative-test FAILED: plain image did not reject STATIC_PHP_SITES with the expected message\n'; printf '%s\n' "$neg_logs"; exit 1; }

printf 'smoke test passed\n'
