#!/bin/bash
# End-to-end smoke for the WITH_PHP=1 image variant.
# Mirrors tests/smoke.sh (so static / proxy / redirect / ACME assertions all
# rerun against the -php image, proving the PHP variant hasn't regressed the
# non-PHP surface) and adds PHP-specific positive and negative assertions plus
# the cgi-fcgi /ping endpoint probe.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/.tmp-smoke.XXXXXX")"
COMPOSE_FILE="$TMP_DIR/docker-compose.yaml"
HTTP_PORT="${HTTP_PORT:-18180}"
HTTPS_PORT="${HTTPS_PORT:-18543}"

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

mkdir -p "$TMP_DIR/backend" "$TMP_DIR/custom" "$TMP_DIR/php-site" "$TMP_DIR/static-site"
printf 'backend OK\n'           > "$TMP_DIR/backend/index.html"
printf 'custom root OK\n'       > "$TMP_DIR/custom/index.html"

# PHP site fixture content.
cat > "$TMP_DIR/php-site/index.php" <<'PHPEOF'
<?php echo "php-index-ok"; ?>
PHPEOF
cat > "$TMP_DIR/php-site/version.php" <<'PHPEOF'
<?php echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION; ?>
PHPEOF
cat > "$TMP_DIR/php-site/hello.php" <<'PHPEOF'
<?php echo "hello-from-php"; ?>
PHPEOF
# Rewrite target: echoes back the captured ?code= query argument so we can prove
# an internal rewrite reaches PHP with the rewritten query string intact.
cat > "$TMP_DIR/php-site/lookup.php" <<'PHPEOF'
<?php echo "code=" . preg_replace('/[^A-Z0-9-]/', '', $_GET['code'] ?? ''); ?>
PHPEOF

# Static-site fixture: drop a .php file that MUST NOT be executed.
cat > "$TMP_DIR/static-site/index.html" <<'HTMLEOF'
<html><body>static-site OK</body></html>
HTMLEOF
cat > "$TMP_DIR/static-site/bad.php" <<'PHPEOF'
<?php echo "SHOULD-NOT-EXECUTE"; ?>
PHPEOF

cat > "$COMPOSE_FILE" <<EOF
services:
  proxy:
    build:
      context: "$ROOT_DIR/nginx-auto-tls-proxy"
      args:
        WITH_PHP: "1"
    ports:
      - "127.0.0.1:$HTTP_PORT:80"
      - "127.0.0.1:$HTTPS_PORT:443"
    volumes:
      - "$TMP_DIR/ssl:/ssl"
      - "$TMP_DIR/sites:/sites"
      - "$TMP_DIR/custom:/custom/custom.local"
      - "$TMP_DIR/php-site:/sites/php.local"
      - "$TMP_DIR/static-site:/sites/static.local"
    environment:
      STATIC_SITES: "default.local,custom.local,static.local"
      STATIC_PHP_SITES: "php.local"
      STATIC_SITE_ROOTS: "custom.local:/custom/custom.local"
      PROXY_SITES: "proxy.local:http://backend/"
      SITE_ALIASES: "default.local:www.default.local,php.local:www.php.local"
      SITE_REWRITES: |
        php.local ^/code/([A-Z]{4}-[A-Z]{4})\$ /lookup.php?code=\$1
      SITE_ALLOWED_IPS: "php.local:10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,[2001:db8::/32]"
      LETSENCRYPT_EMAIL: ""
      CLIENT_MAX_BODY_SIZE: "16m"
      PROXY_READ_TIMEOUT: "60s"
      PROXY_SEND_TIMEOUT: "60s"
      PHP_FPM_PROFILE: "M"
      PHP_MEMORY_LIMIT: "128M"
      PHP_MAX_EXECUTION_TIME: "30"
  backend:
    image: nginx:alpine
    volumes:
      - "$TMP_DIR/backend:/usr/share/nginx/html:ro"
EOF

# Fixtures must be readable by the in-container nginx user (uid 101). Use
# chmod a+r/x rather than chown — chown on bind mounts is unreliable across
# macOS / Linux / rootless docker setups.
chmod -R a+rX "$TMP_DIR/php-site" "$TMP_DIR/static-site" "$TMP_DIR/custom" "$TMP_DIR/backend"

"${COMPOSE[@]}" up -d --build

for _ in $(seq 1 60); do
    if "${COMPOSE[@]}" exec -T proxy /usr/local/bin/healthcheck.sh >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
"${COMPOSE[@]}" exec -T proxy /usr/local/bin/healthcheck.sh

"${COMPOSE[@]}" exec -T proxy sh -c \
    'mkdir -p /var/www/acme/.well-known/acme-challenge && printf challenge-ok > /var/www/acme/.well-known/acme-challenge/smoke-token'

# --- Repeat the static / proxy / redirect / ACME assertions on the -php image. ---

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

# --- PHP-specific positives. ---

# index.php served as the directory index when the URL is the docroot.
body="$(curl -fksS --resolve "php.local:$HTTPS_PORT:127.0.0.1" "https://php.local:$HTTPS_PORT/")"
printf '%s\n' "$body" | grep -q 'php-index-ok' \
    || { printf 'FAIL: directory-index php did not execute, got: %s\n' "$body"; exit 1; }

# Explicit *.php request returns 200 + body.
body="$(curl -fksS --resolve "php.local:$HTTPS_PORT:127.0.0.1" "https://php.local:$HTTPS_PORT/hello.php")"
printf '%s\n' "$body" | grep -q 'hello-from-php' \
    || { printf 'FAIL: explicit .php request did not return expected body, got: %s\n' "$body"; exit 1; }

# phpinfo()-style version probe matches PHP 8.5.x (the documented v1 default).
body="$(curl -fksS --resolve "php.local:$HTTPS_PORT:127.0.0.1" "https://php.local:$HTTPS_PORT/version.php")"
printf '%s\n' "$body" | grep -q '^8\.5$' \
    || { printf 'FAIL: PHP version is not 8.5.x, got: %s\n' "$body"; exit 1; }

# Alias inherits primary's PHP behavior — www.php.local serves PHP too.
body="$(curl -fksS --resolve "www.php.local:$HTTPS_PORT:127.0.0.1" "https://www.php.local:$HTTPS_PORT/hello.php")"
printf '%s\n' "$body" | grep -q 'hello-from-php' \
    || { printf 'FAIL: alias of PHP primary did not serve PHP, got: %s\n' "$body"; exit 1; }

# --- SITE_REWRITES into PHP: pretty URL is rewritten internally to a PHP script. ---
# The client URL does not change (200, not 302) and the rewritten ?code= query
# reaches PHP.
rewrite_code="$(curl -ksS -o /dev/null -w '%{http_code}' \
    --resolve "php.local:$HTTPS_PORT:127.0.0.1" "https://php.local:$HTTPS_PORT/code/ASDF-YUIO")"
[[ "$rewrite_code" == "200" ]] \
    || { printf 'FAIL: PHP internal rewrite returned %s, expected 200\n' "$rewrite_code"; exit 1; }
body="$(curl -fksS --resolve "php.local:$HTTPS_PORT:127.0.0.1" "https://php.local:$HTTPS_PORT/code/ASDF-YUIO")"
printf '%s\n' "$body" | grep -q '^code=ASDF-YUIO$' \
    || { printf 'FAIL: rewrite to PHP did not pass the captured query, got: %s\n' "$body"; exit 1; }

# --- PHP-specific negative: .php under a plain STATIC_SITES entry must NOT execute. ---
# In strict-routing mode the .php file is matched by `location ~ \.php$` (which
# does not exist on non-PHP server blocks) — so it falls through to the static
# location and is served as text, OR is returned as 404 by the catch-all. Either
# way it MUST NOT be executed. We assert "not executed" by checking that the
# response either contains the literal `<?php` source markers (= served as
# text) OR is a 4xx/5xx status (= not served at all). Executed output would
# be just `SHOULD-NOT-EXECUTE` with no PHP markers.
body="$(curl -ksS --resolve "static.local:$HTTPS_PORT:127.0.0.1" "https://static.local:$HTTPS_PORT/bad.php" || true)"
code="$(curl -ksS -o /dev/null -w '%{http_code}' --resolve "static.local:$HTTPS_PORT:127.0.0.1" "https://static.local:$HTTPS_PORT/bad.php" || true)"
if [[ "$code" == "200" ]] && ! printf '%s' "$body" | grep -q '<?php'; then
    printf 'FAIL: .php file under a non-PHP STATIC_SITES entry was EXECUTED (security regression!). Code=%s Body: %s\n' "$code" "$body"
    exit 1
fi
# Confirm the file is in fact present in the static docroot (so we know the test
# actually exercised the right scenario — i.e. the absence of execution is from
# nginx config, not from a missing fixture).
"${COMPOSE[@]}" exec -T proxy test -f /sites/static.local/bad.php \
    || { printf 'FAIL: bad.php fixture not present in static-site docroot inside the container\n'; exit 1; }

# --- SITE_ALLOWED_IPS on a static-php site. ---
# The allow/deny list must be emitted on the static-php HTTPS block; because the
# test client's IP (Docker bridge gateway) is within the allowed RFC1918 ranges,
# every PHP assertion above still returned 200 with the list in force.
"${COMPOSE[@]}" exec -T proxy sh -c \
    'grep -q "allow 172.16.0.0/12;" /etc/nginx/conf.d/nginx-auto-tls-proxy-php.local.conf \
     && grep -q "allow 2001:db8::/32;" /etc/nginx/conf.d/nginx-auto-tls-proxy-php.local.conf \
     && grep -q "deny all;" /etc/nginx/conf.d/nginx-auto-tls-proxy-php.local.conf' \
    || { printf 'FAIL: SITE_ALLOWED_IPS did not emit allow/deny on the static-php block\n'; exit 1; }

# --- FastCGI /ping endpoint returns "pong". ---
ping_response="$("${COMPOSE[@]}" exec -T proxy sh -c '
    SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET QUERY_STRING= \
    cgi-fcgi -bind -connect /run/php-fpm.sock' 2>/dev/null || true)"
printf '%s\n' "$ping_response" | grep -q '^pong$' \
    || { printf 'FAIL: cgi-fcgi /ping did not return pong; got: %s\n' "$ping_response"; exit 1; }

# --- Hardening: zz-defaults.ini is loaded and reports the expected directives. ---
"${COMPOSE[@]}" exec -T proxy sh -c '
    php85 -r "
        echo (ini_get(\"expose_php\") ? \"FAIL-expose_php\" : \"ok-expose_php\") . \"\\n\";
        echo (ini_get(\"display_errors\") ? \"FAIL-display_errors\" : \"ok-display_errors\") . \"\\n\";
        echo (ini_get(\"cgi.fix_pathinfo\") ? \"FAIL-fix_pathinfo\" : \"ok-fix_pathinfo\") . \"\\n\";
        echo (ini_get(\"session.cookie_httponly\") ? \"ok-httponly\" : \"FAIL-httponly\") . \"\\n\";
        echo (ini_get(\"session.cookie_secure\") ? \"ok-secure\" : \"FAIL-secure\") . \"\\n\";
    "' \
    | tee "$TMP_DIR/hardening.out"
grep -q '^FAIL' "$TMP_DIR/hardening.out" && { printf 'FAIL: PHP hardening defaults not as expected; see above\n'; exit 1; } || true

# --- Curated denylist returns 404 for sensitive paths on PHP sites. ---
for path in /.git/config /.env /composer.json /vendor/foo.php; do
    code="$(curl -ksS -o /dev/null -w '%{http_code}' --resolve "php.local:$HTTPS_PORT:127.0.0.1" "https://php.local:$HTTPS_PORT${path}")"
    if [[ "$code" != "404" ]]; then
        printf 'FAIL: denylist did not return 404 for %s, got: %s\n' "$path" "$code"
        exit 1
    fi
done

# --- Derived ini values are present. ---
"${COMPOSE[@]}" exec -T proxy test -f /etc/nginx-auto-tls-proxy/php/conf.d/zz-derived.ini
"${COMPOSE[@]}" exec -T proxy grep -q 'memory_limit = 128M'         /etc/nginx-auto-tls-proxy/php/conf.d/zz-derived.ini
"${COMPOSE[@]}" exec -T proxy grep -q 'upload_max_filesize = 16M'   /etc/nginx-auto-tls-proxy/php/conf.d/zz-derived.ini

# --- Stable image paths exist (track-decoupling check). ---
"${COMPOSE[@]}" exec -T proxy test -L /usr/local/sbin/php-fpm
"${COMPOSE[@]}" exec -T proxy test -L /etc/nginx-auto-tls-proxy/php

printf 'php smoke test passed\n'
