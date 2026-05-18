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

# Tear down the main stack before the negative-test substack, so we don't fight
# over container names / ports.
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

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
