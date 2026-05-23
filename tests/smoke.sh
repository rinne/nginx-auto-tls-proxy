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
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/backend" "$TMP_DIR/custom"
printf 'backend OK\n' > "$TMP_DIR/backend/index.html"
printf 'custom root OK\n' > "$TMP_DIR/custom/index.html"

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
      STATIC_SITES: "default.local,custom.local"
      STATIC_SITE_ROOTS: "custom.local:/custom/custom.local"
      PROXY_SITES: "proxy.local:http://backend/"
      SITE_ALIASES: "default.local:www.default.local"
      SITE_REDIRECTS: "shallow.local:default.local,deep.local:default.local:deep,explicit.local:default.local:no-deep"
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
     && grep -q 'proxy_pass \$upstream_proxy_local' /etc/nginx/conf.d/nginx-auto-tls-proxy-proxy.local.conf"

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

# Tear down the main stack before the negative-test substack, so we don't fight
# over container names / ports.
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

# --- HTTPS_PORT_OVERRIDE config generation (DRY_RUN) ---
PORT_IMG="$("${COMPOSE[@]}" images -q proxy 2>/dev/null || docker images -q tmp-smoke*-proxy 2>/dev/null | head -1)"
# Use the already-built image for DRY_RUN config checks.
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
    "$PORT_IMG" 2>&1 \
    | grep -q 'stream cannot share ports via SNI' \
    || { printf 'FAIL: should reject duplicate stream ports\n'; exit 1; }

# Port conflict with HTTPS_PORT_OVERRIDE
docker run --rm \
    -e STATIC_SITES="a.local" \
    -e HTTPS_PORT_OVERRIDE="a.local:4444" \
    -e TLS_TERMINATOR_PROXY="b.local:4444:bg:80" \
    -e DRY_RUN=1 \
    "$PORT_IMG" 2>&1 \
    | grep -q 'conflicts with HTTPS_PORT_OVERRIDE' \
    || { printf 'FAIL: should reject stream port conflicting with HTTPS_PORT_OVERRIDE\n'; exit 1; }

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
