#!/bin/bash
# Certbot deploy hook. Copies renewed certs into the stable /ssl/<domain> layout
# used by generated nginx configs, then reloads nginx when it is running.
set -uo pipefail

log()  { echo "[certbot-deploy] $*"; }
warn() { echo "[certbot-deploy] WARNING: $*" >&2; }
err()  { echo "[certbot-deploy] ERROR: $*" >&2; }

[[ -n "${RENEWED_LINEAGE:-}" ]] || exit 0

domain="$(basename "$RENEWED_LINEAGE")"
ssl_dir="/ssl/$domain"

for file in privkey.pem fullchain.pem chain.pem; do
    if [[ ! -f "$RENEWED_LINEAGE/$file" ]]; then
        err "Missing $RENEWED_LINEAGE/$file"
        exit 1
    fi
done

log "Deploying LE cert for $domain to $ssl_dir"
mkdir -p "$ssl_dir"
cp "$RENEWED_LINEAGE/privkey.pem" "$ssl_dir/ssl.key"
cp "$RENEWED_LINEAGE/fullchain.pem" "$ssl_dir/ssl.crt"
cp "$RENEWED_LINEAGE/chain.pem" "$ssl_dir/chain.crt"
chmod 600 "$ssl_dir/ssl.key"

if [[ -f /var/run/nginx.pid ]] && kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null; then
    if nginx -t >/dev/null 2>&1; then
        log "Reloading nginx"
        nginx -s reload
    else
        warn "nginx config test failed; skipping reload"
    fi
else
    warn "nginx is not running; cert deployed without reload"
fi
