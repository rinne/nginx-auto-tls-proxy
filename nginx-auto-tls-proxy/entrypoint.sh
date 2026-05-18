#!/bin/bash
# nginx-auto-tls-proxy entrypoint
# Generates nginx config from environment, prepares static roots and fallback
# certs, then optionally manages Let's Encrypt certificates.
set -uo pipefail

log()  { echo "[nginx-auto-tls-proxy] $*"; }
warn() { echo "[nginx-auto-tls-proxy] WARNING: $*" >&2; }
err()  { echo "[nginx-auto-tls-proxy] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

trim_spaces() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

lower() {
    printf '%s' "${1,,}"
}

is_valid_hostname() {
    local host="$1"
    [[ ${#host} -ge 1 && ${#host} -le 253 ]] || return 1
    [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]
}

require_hostname() {
    local host="$1"
    local source="$2"
    is_valid_hostname "$host" || die "Invalid hostname in $source: $host"
}

is_safe_path() {
    local path="$1"
    [[ "$path" == /* ]] || return 1
    [[ "$path" =~ ^/[A-Za-z0-9._/-]*$ ]]
}

require_safe_path() {
    local path="$1"
    local source="$2"
    is_safe_path "$path" || die "$source must be an absolute path containing only letters, numbers, dot, dash, underscore, and slash: $path"
}

is_safe_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[^[:space:]\;\"\`\$]+$ ]]
}

is_safe_size() {
    [[ "$1" =~ ^[0-9]+[kKmMgG]?$ ]]
}

is_safe_duration() {
    [[ "$1" =~ ^[0-9]+[smhd]?$ ]]
}

is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

site_exists() {
    [[ "${ALL_SITE_MAP["$1"]+isset}" == "isset" ]]
}

site_aliases() {
    printf '%s' "${SITE_ALIASES_MAP["$1"]:-}"
}

site_static_root() {
    local site="$1"
    printf '%s' "${STATIC_ROOT_MAP["$site"]:-/sites/$site}"
}

site_mode() {
    local site="$1"
    if [[ "${PROXY_MAP["$site"]+isset}" == "isset" ]]; then
        printf 'proxy'
    else
        printf 'static'
    fi
}

nginx_auth_lines() {
    local site="$1"
    [[ "${BASIC_AUTH_MAP["$site"]+isset}" == "isset" ]] || return 0
    cat <<EOF
        auth_basic "Restricted";
        auth_basic_user_file ${BASIC_AUTH_MAP["$site"]};
EOF
}

nginx_hsts_line() {
    [[ "${HSTS_MAX_AGE:-0}" != "0" ]] || return 0
    printf '    add_header Strict-Transport-Security "max-age=%s" always;\n' "$HSTS_MAX_AGE"
}

nginx_ocsp_lines() {
    local site="$1"
    [[ "${OCSP_STAPLING:-0}" == "1" ]] || return 0
    cat <<EOF
    ssl_trusted_certificate /ssl/$site/chain.crt;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 valid=300s;
    resolver_timeout 5s;
EOF
}

nginx_static_fallback_lines() {
    [[ "${STATIC_FALLBACK_PAGES:-0}" == "1" ]] || return 0
    cat <<'EOF'
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
EOF
}

cert_source() {
    local site="$1"
    local cert="/ssl/$site/ssl.crt"
    [[ -f "$cert" ]] || { printf 'missing'; return 0; }
    if openssl x509 -in "$cert" -noout -issuer 2>/dev/null | grep -qi "Let's Encrypt"; then
        printf 'letsencrypt'
    else
        printf 'self-signed'
    fi
}

cert_has_domain() {
    local cert="$1"
    local domain="$2"
    openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' \
        | tr -d ' ' \
        | grep -Fxq "DNS:$domain"
}

le_cert_current_for_site() {
    local site="$1"
    local cert="$CERTBOT_CONFIG_DIR/live/$site/fullchain.pem"
    [[ -f "$cert" ]] || return 1
    openssl x509 -in "$cert" -checkend "$LE_RENEW_BEFORE_SECONDS" -noout >/dev/null 2>&1 || return 1
    cert_has_domain "$cert" "$site" || return 1
    local alias
    for alias in $(site_aliases "$site"); do
        cert_has_domain "$cert" "$alias" || return 1
    done
}

deploy_existing_le_cert() {
    local site="$1"
    local lineage="$CERTBOT_CONFIG_DIR/live/$site"
    [[ -d "$lineage" ]] || return 1
    RENEWED_LINEAGE="$lineage" /usr/local/bin/certbot-deploy.sh || return 1
}

# Basic volume and directory setup.
if ! grep -qs " /ssl " /proc/mounts 2>/dev/null; then
    warn "/ssl is not mounted as a volume. TLS certificates will not persist across restarts."
fi

mkdir -p \
    /var/www/acme/.well-known/acme-challenge \
    /etc/nginx/conf.d \
    /etc/nginx/site-conf.d \
    /ssl \
    /sites

declare -A STATIC_SITE_MAP=()
declare -A PROXY_MAP=()
declare -A SITE_ALIASES_MAP=()
declare -A STATIC_ROOT_MAP=()
declare -A ALL_SITE_MAP=()
declare -A SERVER_NAME_OWNER=()
declare -A BASIC_AUTH_MAP=()
declare -a STATIC_SITES_ARR=()
declare -a PROXY_SITES_ARR=()
declare -a ALL_SITES=()

# Static sites: STATIC_SITES=domain.com,domain2.com
if [[ -n "${STATIC_SITES:-}" ]]; then
    IFS=',' read -ra _parts <<< "$STATIC_SITES"
    for _p in "${_parts[@]}"; do
        _site="$(lower "$(trim_spaces "$_p")")"
        [[ -z "$_site" ]] && continue
        require_hostname "$_site" "STATIC_SITES"
        [[ "${STATIC_SITE_MAP["$_site"]+isset}" == "isset" ]] && die "Duplicate STATIC_SITES entry: $_site"
        STATIC_SITE_MAP["$_site"]=1
        STATIC_SITES_ARR+=("$_site")
        ALL_SITE_MAP["$_site"]=1
        ALL_SITES+=("$_site")
    done
fi

# Proxy sites: PROXY_SITES=app.com:http://backend:3000/
if [[ -n "${PROXY_SITES:-}" ]]; then
    IFS=',' read -ra _parts <<< "$PROXY_SITES"
    for _p in "${_parts[@]}"; do
        _p="$(trim_spaces "$_p")"
        [[ -z "$_p" ]] && continue
        [[ "$_p" == *:* ]] || die "Malformed PROXY_SITES entry, expected domain:upstream-url: $_p"
        _site="$(lower "$(trim_spaces "${_p%%:*}")")"
        _url="$(trim_spaces "${_p#*:}")"
        require_hostname "$_site" "PROXY_SITES"
        is_safe_url "$_url" || die "Invalid upstream URL for $_site in PROXY_SITES: $_url"
        [[ "${STATIC_SITE_MAP["$_site"]+isset}" == "isset" ]] && die "$_site is configured in both STATIC_SITES and PROXY_SITES"
        [[ "${PROXY_MAP["$_site"]+isset}" == "isset" ]] && die "Duplicate PROXY_SITES entry: $_site"
        PROXY_MAP["$_site"]="$_url"
        PROXY_SITES_ARR+=("$_site")
        ALL_SITE_MAP["$_site"]=1
        ALL_SITES+=("$_site")
    done
fi

# Aliases: SITE_ALIASES=domain.com:www.domain.com,old.example.com,domain2.com:www.domain2.com
if [[ -n "${SITE_ALIASES:-}" ]]; then
    _current_site=""
    IFS=',' read -ra _parts <<< "$SITE_ALIASES"
    for _p in "${_parts[@]}"; do
        _p="$(trim_spaces "$_p")"
        [[ -z "$_p" ]] && continue
        if [[ "$_p" == *:* ]]; then
            _current_site="$(lower "$(trim_spaces "${_p%%:*}")")"
            _alias="$(lower "$(trim_spaces "${_p#*:}")")"
            require_hostname "$_current_site" "SITE_ALIASES"
            require_hostname "$_alias" "SITE_ALIASES"
            [[ "$_alias" == "$_current_site" ]] && die "Alias cannot equal primary site in SITE_ALIASES: $_alias"
            SITE_ALIASES_MAP["$_current_site"]="${SITE_ALIASES_MAP["$_current_site"]:-} $_alias"
        elif [[ -n "$_current_site" ]]; then
            _alias="$(lower "$_p")"
            require_hostname "$_alias" "SITE_ALIASES"
            [[ "$_alias" == "$_current_site" ]] && die "Alias cannot equal primary site in SITE_ALIASES: $_alias"
            SITE_ALIASES_MAP["$_current_site"]="${SITE_ALIASES_MAP["$_current_site"]:-} $_alias"
        else
            die "SITE_ALIASES must start with a primary:alias entry before bare aliases: $_p"
        fi
    done
fi

# Custom roots for static sites: STATIC_SITE_ROOTS=domain.com:/custom/htdocs
if [[ -n "${STATIC_SITE_ROOTS:-}" ]]; then
    IFS=',' read -ra _parts <<< "$STATIC_SITE_ROOTS"
    for _p in "${_parts[@]}"; do
        _p="$(trim_spaces "$_p")"
        [[ -z "$_p" ]] && continue
        [[ "$_p" == *:* ]] || die "Malformed STATIC_SITE_ROOTS entry, expected domain:absolute-path: $_p"
        _site="$(lower "$(trim_spaces "${_p%%:*}")")"
        _root="$(trim_spaces "${_p#*:}")"
        require_hostname "$_site" "STATIC_SITE_ROOTS"
        require_safe_path "$_root" "STATIC_SITE_ROOTS root for $_site"
        [[ "${STATIC_SITE_MAP["$_site"]+isset}" == "isset" ]] || die "STATIC_SITE_ROOTS entry for $_site has no matching STATIC_SITES entry"
        STATIC_ROOT_MAP["$_site"]="$_root"
    done
fi

# Optional basic auth: BASIC_AUTH_FILES=domain.com:/run/secrets/domain.htpasswd
if [[ -n "${BASIC_AUTH_FILES:-}" ]]; then
    IFS=',' read -ra _parts <<< "$BASIC_AUTH_FILES"
    for _p in "${_parts[@]}"; do
        _p="$(trim_spaces "$_p")"
        [[ -z "$_p" ]] && continue
        [[ "$_p" == *:* ]] || die "Malformed BASIC_AUTH_FILES entry, expected domain:absolute-path: $_p"
        _site="$(lower "$(trim_spaces "${_p%%:*}")")"
        _file="$(trim_spaces "${_p#*:}")"
        require_hostname "$_site" "BASIC_AUTH_FILES"
        require_safe_path "$_file" "BASIC_AUTH_FILES path for $_site"
        site_exists "$_site" || die "BASIC_AUTH_FILES entry for $_site has no matching site"
        BASIC_AUTH_MAP["$_site"]="$_file"
    done
fi

# Validate alias ownership and duplicate server names.
for _site in "${ALL_SITES[@]}"; do
    SERVER_NAME_OWNER["$_site"]="$_site"
done

for _site in "${!SITE_ALIASES_MAP[@]}"; do
    site_exists "$_site" || die "SITE_ALIASES primary has no matching site: $_site"
    _deduped_aliases=""
    declare -A _alias_seen=()
    for _alias in ${SITE_ALIASES_MAP["$_site"]}; do
        [[ "${_alias_seen["$_alias"]+isset}" == "isset" ]] && continue
        _alias_seen["$_alias"]=1
        if [[ "${SERVER_NAME_OWNER["$_alias"]+isset}" == "isset" && "${SERVER_NAME_OWNER["$_alias"]}" != "$_site" ]]; then
            die "Hostname $_alias is assigned to both ${SERVER_NAME_OWNER["$_alias"]} and $_site"
        fi
        SERVER_NAME_OWNER["$_alias"]="$_site"
        _deduped_aliases="$_deduped_aliases $_alias"
    done
    SITE_ALIASES_MAP["$_site"]="$_deduped_aliases"
    unset _alias_seen
done

DEFAULT_SITE="$(lower "$(trim_spaces "${DEFAULT_SITE:-}")")"
if [[ -n "$DEFAULT_SITE" ]]; then
    site_exists "$DEFAULT_SITE" || die "DEFAULT_SITE must match a configured primary site: $DEFAULT_SITE"
fi

CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-16m}"
PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-60s}"
PROXY_SEND_TIMEOUT="${PROXY_SEND_TIMEOUT:-60s}"
HSTS_MAX_AGE="${HSTS_MAX_AGE:-0}"
OCSP_STAPLING="${OCSP_STAPLING:-0}"
STATIC_FALLBACK_PAGES="${STATIC_FALLBACK_PAGES:-0}"
REAL_IP_HEADER="${REAL_IP_HEADER:-X-Forwarded-For}"
LETSENCRYPT_RENEW_INTERVAL_SECONDS="${LETSENCRYPT_RENEW_INTERVAL_SECONDS:-43200}"
LE_RENEW_BEFORE_DAYS="${LE_RENEW_BEFORE_DAYS:-30}"

is_safe_size "$CLIENT_MAX_BODY_SIZE" || die "CLIENT_MAX_BODY_SIZE must look like 16m, 512k, or 1g"
is_safe_duration "$PROXY_READ_TIMEOUT" || die "PROXY_READ_TIMEOUT must look like 60s, 5m, or 1h"
is_safe_duration "$PROXY_SEND_TIMEOUT" || die "PROXY_SEND_TIMEOUT must look like 60s, 5m, or 1h"
[[ "$HSTS_MAX_AGE" =~ ^[0-9]+$ ]] || die "HSTS_MAX_AGE must be a non-negative integer"
[[ "$OCSP_STAPLING" == "0" || "$OCSP_STAPLING" == "1" ]] || die "OCSP_STAPLING must be 0 or 1"
[[ "$STATIC_FALLBACK_PAGES" == "0" || "$STATIC_FALLBACK_PAGES" == "1" ]] || die "STATIC_FALLBACK_PAGES must be 0 or 1"
[[ "$REAL_IP_HEADER" =~ ^[A-Za-z0-9-]+$ ]] || die "REAL_IP_HEADER must be an HTTP header name"
is_positive_int "$LETSENCRYPT_RENEW_INTERVAL_SECONDS" || die "LETSENCRYPT_RENEW_INTERVAL_SECONDS must be a positive integer"
is_positive_int "$LE_RENEW_BEFORE_DAYS" || die "LE_RENEW_BEFORE_DAYS must be a positive integer"
LE_RENEW_BEFORE_SECONDS=$((LE_RENEW_BEFORE_DAYS * 86400))

log "Sites: ${ALL_SITES[*]:-<none>}"

# Prepare static roots and placeholder content.
for _site in "${STATIC_SITES_ARR[@]}"; do
    _dir="$(site_static_root "$_site")"
    mkdir -p "$_dir"
    if [[ ! -f "$_dir/index.html" ]]; then
        log "Creating placeholder index.html for $_site in $_dir"
        cat > "$_dir/index.html" <<HTMLEOF
<!DOCTYPE html>
<html>
<head><title>$_site</title></head>
<body>
<h1>$(hostname)</h1>
<p>Site: $_site</p>
</body>
</html>
HTMLEOF
    fi
    if [[ "$STATIC_FALLBACK_PAGES" == "1" && ! -f "$_dir/404.html" ]]; then
        cat > "$_dir/404.html" <<HTMLEOF
<!DOCTYPE html>
<html>
<head><title>Not found - $_site</title></head>
<body>
<h1>Not found</h1>
<p>Site: $_site</p>
</body>
</html>
HTMLEOF
    fi
    if [[ "$STATIC_FALLBACK_PAGES" == "1" && ! -f "$_dir/50x.html" ]]; then
        cat > "$_dir/50x.html" <<HTMLEOF
<!DOCTYPE html>
<html>
<head><title>Server error - $_site</title></head>
<body>
<h1>Server error</h1>
<p>Site: $_site</p>
</body>
</html>
HTMLEOF
    fi
done

create_selfsigned_cert() {
    local site="$1"
    local ssl_dir="/ssl/$site"

    if [[ -f "$ssl_dir/ssl.crt" && -f "$ssl_dir/ssl.key" ]]; then
        log "Cert already present for $site ($(cert_source "$site"))"
        return 0
    fi

    log "Generating self-signed cert for $site"
    mkdir -p "$ssl_dir"

    local san="DNS:$site"
    local alias
    for alias in $(site_aliases "$site"); do
        san="$san,DNS:$alias"
    done

    if ! openssl req -x509 \
            -newkey rsa:2048 \
            -keyout "$ssl_dir/ssl.key" \
            -out    "$ssl_dir/ssl.crt" \
            -days   365 \
            -nodes \
            -subj   "/CN=$site" \
            -addext "subjectAltName=$san" \
            2>/dev/null; then
        err "openssl failed for $site"
        return 1
    fi

    cp "$ssl_dir/ssl.crt" "$ssl_dir/chain.crt"
    chmod 600 "$ssl_dir/ssl.key"
    log "Self-signed cert created for $site (SAN: $san)"
}

for _site in "${ALL_SITES[@]}"; do
    create_selfsigned_cert "$_site" || warn "Could not create cert for $_site"
done

generate_real_ip_config() {
    [[ -n "${REAL_IP_FROM:-}" ]] || return 0
    local conf="/etc/nginx/conf.d/nginx-auto-tls-proxy-01-real-ip.conf"
    : > "$conf"
    IFS=',' read -ra _real_ip_sources <<< "$REAL_IP_FROM"
    local source
    for source in "${_real_ip_sources[@]}"; do
        source="$(trim_spaces "$source")"
        [[ -z "$source" ]] && continue
        [[ "$source" =~ ^[A-Za-z0-9:./_-]+$ ]] || die "Unsafe REAL_IP_FROM value: $source"
        printf 'set_real_ip_from %s;\n' "$source" >> "$conf"
    done
    cat >> "$conf" <<EOF
real_ip_header $REAL_IP_HEADER;
real_ip_recursive on;
EOF
}

generate_site_config() {
    local site="$1"
    local conf="/etc/nginx/conf.d/nginx-auto-tls-proxy-${site}.conf"
    local server_names="$site"
    local alias

    for alias in $(site_aliases "$site"); do
        server_names="$server_names $alias"
    done

    cat > "$conf" <<NGINXEOF
server {
    listen 80;
    server_name $server_names;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        try_files \$uri =404;
    }

    location / {
        return 302 https://$site\$request_uri;
    }
}

NGINXEOF

    if [[ "$(site_mode "$site")" == "proxy" ]]; then
        local proxy_url="${PROXY_MAP["$site"]}"
        cat >> "$conf" <<NGINXEOF
server {
    listen 443 ssl;
    http2 on;
    server_name $server_names;

    ssl_certificate     /ssl/$site/ssl.crt;
    ssl_certificate_key /ssl/$site/ssl.key;
$(nginx_ocsp_lines "$site")
    client_max_body_size $CLIENT_MAX_BODY_SIZE;
$(nginx_hsts_line)
    include /etc/nginx/site-conf.d/$site/*.conf;

    location / {
$(nginx_auth_lines "$site")
        proxy_pass $proxy_url;
        proxy_http_version 1.1;
        proxy_set_header Host              \$http_host;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port  \$server_port;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        proxy_read_timeout                 $PROXY_READ_TIMEOUT;
        proxy_send_timeout                 $PROXY_SEND_TIMEOUT;
    }
}
NGINXEOF
    else
        local site_root
        site_root="$(site_static_root "$site")"
        cat >> "$conf" <<NGINXEOF
server {
    listen 443 ssl;
    http2 on;
    server_name $server_names;

    ssl_certificate     /ssl/$site/ssl.crt;
    ssl_certificate_key /ssl/$site/ssl.key;
$(nginx_ocsp_lines "$site")
    client_max_body_size $CLIENT_MAX_BODY_SIZE;
$(nginx_hsts_line)
    include /etc/nginx/site-conf.d/$site/*.conf;

    root "$site_root";
    index index.html index.htm;
$(nginx_static_fallback_lines)

    location / {
$(nginx_auth_lines "$site")
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF
    fi

    log "Config written for $site"
}

print_startup_summary() {
    log "Startup site plan:"
    if [[ ${#ALL_SITES[@]} -eq 0 ]]; then
        log "  <no sites configured>"
        return 0
    fi
    local site mode aliases target
    for site in "${ALL_SITES[@]}"; do
        mode="$(site_mode "$site")"
        aliases="$(trim_spaces "$(site_aliases "$site")")"
        if [[ "$mode" == "proxy" ]]; then
            target="${PROXY_MAP["$site"]}"
        else
            target="$(site_static_root "$site")"
        fi
        log "  $site mode=$mode aliases=${aliases:-<none>} target=$target cert=$(cert_source "$site")"
    done
}

# Remove only configs generated by this image. Mounted custom snippets are left alone.
rm -f /etc/nginx/conf.d/nginx-auto-tls-proxy-*.conf

cat > /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf <<NGINXEOF
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        try_files \$uri =404;
    }

    location / {
NGINXEOF

if [[ -n "$DEFAULT_SITE" ]]; then
    cat >> /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf <<NGINXEOF
        return 302 https://$DEFAULT_SITE\$request_uri;
NGINXEOF
else
    cat >> /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf <<'NGINXEOF'
        return 404;
NGINXEOF
fi

cat >> /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf <<'NGINXEOF'
    }
}

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
NGINXEOF

generate_real_ip_config

if [[ ${#ALL_SITES[@]} -gt 0 ]]; then
    for _site in "${ALL_SITES[@]}"; do
        generate_site_config "$_site"
    done
else
    log "No sites configured."
fi

print_startup_summary

log "Testing nginx config..."
if ! nginx -t 2>&1; then
    die "nginx config test failed"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN=1 set; nginx and certbot will not be started."
    exit 0
fi

log "Starting nginx..."
nginx -g 'daemon off;' &
NGINX_PID=$!

_shutdown() {
    log "Shutting down nginx..."
    kill "$NGINX_PID" 2>/dev/null || true
    wait "$NGINX_PID" 2>/dev/null || true
}
trap '_shutdown; exit 0' SIGTERM SIGINT
trap 'nginx -s reload' SIGHUP

sleep 2

CERTBOT_BASE_DIR="/ssl/letsencrypt"
CERTBOT_CONFIG_DIR="$CERTBOT_BASE_DIR/config"
CERTBOT_WORK_DIR="$CERTBOT_BASE_DIR/work"
CERTBOT_LOGS_DIR="$CERTBOT_BASE_DIR/logs"

if [[ -n "${LETSENCRYPT_EMAIL:-}" && "${LETSENCRYPT_DISABLE:-0}" != "1" ]]; then
    log "Let's Encrypt enabled (email: $LETSENCRYPT_EMAIL)"
    mkdir -p "$CERTBOT_CONFIG_DIR" "$CERTBOT_WORK_DIR" "$CERTBOT_LOGS_DIR"

    _cb_args=(
        "--non-interactive"
        "--agree-tos"
        "--email" "$LETSENCRYPT_EMAIL"
        "--webroot" "-w" "/var/www/acme"
        "--config-dir" "$CERTBOT_CONFIG_DIR"
        "--work-dir" "$CERTBOT_WORK_DIR"
        "--logs-dir" "$CERTBOT_LOGS_DIR"
        "--deploy-hook" "/usr/local/bin/certbot-deploy.sh"
    )
    [[ "${LETSENCRYPT_STAGING:-0}" == "1" ]] && {
        _cb_args+=("--staging")
        log "Using LE staging server"
    }

    for _site in "${ALL_SITES[@]}"; do
        _domains=("-d" "$_site")
        for _alias in $(site_aliases "$_site"); do
            _domains+=("-d" "$_alias")
        done

        if le_cert_current_for_site "$_site"; then
            log "Valid LE cert already present for $_site; deploying existing lineage"
            deploy_existing_le_cert "$_site" || warn "Could not deploy existing LE cert for $_site"
            continue
        fi

        log "Requesting or updating LE cert for $_site (${_domains[*]})"
        certbot certonly \
            "${_cb_args[@]}" \
            "--cert-name" "$_site" \
            "--keep-until-expiring" \
            "--expand" \
            "${_domains[@]}" || warn "LE cert request failed for $_site; self-signed cert remains in use"
    done

    (
        while true; do
            sleep "$LETSENCRYPT_RENEW_INTERVAL_SECONDS"
            log "Running certbot renewal check..."
            certbot renew \
                "--config-dir" "$CERTBOT_CONFIG_DIR" \
                "--work-dir" "$CERTBOT_WORK_DIR" \
                "--logs-dir" "$CERTBOT_LOGS_DIR" \
                "--deploy-hook" "/usr/local/bin/certbot-deploy.sh" \
                --quiet 2>&1 || warn "certbot renew had issues"
        done
    ) &
    log "LE renewal loop started (every ${LETSENCRYPT_RENEW_INTERVAL_SECONDS}s)"
elif [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
    log "Let's Encrypt disabled by LETSENCRYPT_DISABLE=1"
fi

log "nginx-auto-tls-proxy ready."
wait "$NGINX_PID"
