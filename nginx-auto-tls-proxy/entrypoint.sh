#!/bin/bash
# nginx-auto-tls-proxy entrypoint
# Generates nginx config from environment, prepares static roots and fallback
# certs, then optionally manages Let's Encrypt certificates. When the image is
# built with WITH_PHP=1 and STATIC_PHP_SITES is non-empty, also configures and
# supervises php-fpm.
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

upper() {
    printf '%s' "${1^^}"
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

is_non_negative_int() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

# PHP memory limit: integer + optional K/M/G suffix, or '-1' for unlimited.
is_php_memory_limit() {
    [[ "$1" == "-1" ]] && return 0
    [[ "$1" =~ ^[1-9][0-9]*[KMG]?$ ]]
}

# Convert a nginx-style size (e.g. 16m, 512K, 2g) to PHP-style (uppercase suffix).
# Bare integers pass through unchanged.
nginx_size_to_php() {
    local v="$1"
    if [[ "$v" =~ ^([0-9]+)([kKmMgG])$ ]]; then
        printf '%s%s' "${BASH_REMATCH[1]}" "$(upper "${BASH_REMATCH[2]}")"
    else
        printf '%s' "$v"
    fi
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
    elif [[ "${STATIC_PHP_SITE_MAP["$site"]+isset}" == "isset" ]]; then
        printf 'static-php'
    elif [[ "${REDIRECT_MAP["$site"]+isset}" == "isset" ]]; then
        printf 'redirect'
    elif [[ "${TLS_TERM_MAP["$site"]+isset}" == "isset" ]]; then
        printf 'tls-terminator'
    else
        printf 'static'
    fi
}

is_valid_redirect_mode() {
    [[ "$1" == "deep" || "$1" == "no-deep" ]]
}

site_https_port() {
    local site="$1"
    if [[ "${TLS_TERM_PORT_MAP["$site"]+isset}" == "isset" ]]; then
        printf '%s' "${TLS_TERM_PORT_MAP["$site"]}"
        return
    fi
    if [[ "${SERVER_NAME_OWNER["$site"]+isset}" == "isset" ]]; then
        local primary="${SERVER_NAME_OWNER["$site"]}"
        if [[ "${TLS_TERM_PORT_MAP["$primary"]+isset}" == "isset" ]]; then
            printf '%s' "${TLS_TERM_PORT_MAP["$primary"]}"
            return
        fi
        printf '%s' "${SITE_HTTPS_PORT["$primary"]:-443}"
    else
        printf '443'
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

# Server-level internal rewrites for a site (from SITE_REWRITES). Each stored
# entry is already a fully-quoted `rewrite "<re>" "<repl>" <flag>;` line.
nginx_rewrite_lines() {
    local site="$1"
    [[ "${SITE_REWRITES_MAP["$site"]+isset}" == "isset" ]] || return 0
    printf '%s' "${SITE_REWRITES_MAP["$site"]}"
}

# Curated sensitive-path denylist applied to STATIC_PHP_SITES server blocks.
nginx_php_denylist() {
    cat <<'EOF'
    location ~ /\.                                                                      { deny all; return 404; }
    location ~ ^/(composer\.(json|lock)|package(-lock)?\.json|yarn\.lock|\.env([^/]*)?)$ { deny all; return 404; }
    location ~ \.(bak|swp|orig)$                                                        { deny all; return 404; }
    location ~ ~$                                                                       { deny all; return 404; }
    location ~ ^/(vendor|node_modules)/.*\.php$                                         { deny all; return 404; }
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
declare -A STATIC_PHP_SITE_MAP=()
declare -A PROXY_MAP=()
declare -A REDIRECT_MAP=()
declare -A REDIRECT_MODE_MAP=()
declare -A SITE_REWRITES_MAP=()
declare -A SITE_ALIASES_MAP=()
declare -A STATIC_ROOT_MAP=()
declare -A ALL_SITE_MAP=()
declare -A SERVER_NAME_OWNER=()
declare -A BASIC_AUTH_MAP=()
declare -A HTTPS_PORT_MAP=()
declare -A SITE_HTTPS_PORT=()
declare -A TLS_TERM_MAP=()
declare -A TLS_TERM_PORT_MAP=()
declare -A TLS_TERM_PP_MAP=()
declare -a STATIC_SITES_ARR=()
declare -a STATIC_PHP_SITES_ARR=()
declare -a PROXY_SITES_ARR=()
declare -a REDIRECT_SITES_ARR=()
declare -a TLS_TERM_SITES_ARR=()
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

# PHP-enabled static sites: STATIC_PHP_SITES=blog.example.com,wiki.example.com
# These behave like STATIC_SITES except *.php files are executed via php-fpm.
# Only valid when the image was built with WITH_PHP=1.
if [[ -n "${STATIC_PHP_SITES:-}" ]]; then
    if ! command -v php-fpm >/dev/null 2>&1; then
        die "STATIC_PHP_SITES is set but this image was built without PHP support; use the nginx-auto-tls-proxy:<ver>-php tag"
    fi
    IFS=',' read -ra _parts <<< "$STATIC_PHP_SITES"
    for _p in "${_parts[@]}"; do
        _site="$(lower "$(trim_spaces "$_p")")"
        [[ -z "$_site" ]] && continue
        require_hostname "$_site" "STATIC_PHP_SITES"
        [[ "${STATIC_SITE_MAP["$_site"]+isset}" == "isset" ]] && die "$_site is configured in both STATIC_SITES and STATIC_PHP_SITES"
        [[ "${STATIC_PHP_SITE_MAP["$_site"]+isset}" == "isset" ]] && die "Duplicate STATIC_PHP_SITES entry: $_site"
        STATIC_PHP_SITE_MAP["$_site"]=1
        STATIC_PHP_SITES_ARR+=("$_site")
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
        [[ "${STATIC_PHP_SITE_MAP["$_site"]+isset}" == "isset" ]] && die "$_site is configured in both STATIC_PHP_SITES and PROXY_SITES"
        [[ "${PROXY_MAP["$_site"]+isset}" == "isset" ]] && die "Duplicate PROXY_SITES entry: $_site"
        PROXY_MAP["$_site"]="$_url"
        PROXY_SITES_ARR+=("$_site")
        ALL_SITE_MAP["$_site"]=1
        ALL_SITES+=("$_site")
    done
fi

# Redirect-only sites: SITE_REDIRECTS=source:destination[:mode]
# Mode is 'no-deep' (default, redirects every path to https://destination/)
# or 'deep' (redirects to https://destination + the original request URI).
# Destination is a bare hostname; scheme is implicitly https.
if [[ -n "${SITE_REDIRECTS:-}" ]]; then
    IFS=',' read -ra _parts <<< "$SITE_REDIRECTS"
    for _p in "${_parts[@]}"; do
        _p="$(trim_spaces "$_p")"
        [[ -z "$_p" ]] && continue
        IFS=':' read -ra _fields <<< "$_p"
        if [[ ${#_fields[@]} -lt 2 || ${#_fields[@]} -gt 3 ]]; then
            die "Malformed SITE_REDIRECTS entry, expected source:destination[:mode]: $_p"
        fi
        _src="$(lower "$(trim_spaces "${_fields[0]}")")"
        _dst="$(lower "$(trim_spaces "${_fields[1]}")")"
        if [[ ${#_fields[@]} -eq 3 ]]; then
            _mode="$(lower "$(trim_spaces "${_fields[2]}")")"
        else
            _mode="no-deep"
        fi
        require_hostname "$_src" "SITE_REDIRECTS"
        require_hostname "$_dst" "SITE_REDIRECTS"
        is_valid_redirect_mode "$_mode" || die "SITE_REDIRECTS mode for $_src must be 'no-deep' or 'deep'; got: $_mode"
        [[ "$_src" == "$_dst" ]] && die "Redirect source cannot equal destination in SITE_REDIRECTS: $_src"
        [[ "${STATIC_SITE_MAP["$_src"]+isset}"     == "isset" ]] && die "$_src is configured in both STATIC_SITES and SITE_REDIRECTS"
        [[ "${STATIC_PHP_SITE_MAP["$_src"]+isset}" == "isset" ]] && die "$_src is configured in both STATIC_PHP_SITES and SITE_REDIRECTS"
        [[ "${PROXY_MAP["$_src"]+isset}"           == "isset" ]] && die "$_src is configured in both PROXY_SITES and SITE_REDIRECTS"
        [[ "${REDIRECT_MAP["$_src"]+isset}"        == "isset" ]] && die "Duplicate SITE_REDIRECTS source: $_src"
        REDIRECT_MAP["$_src"]="$_dst"
        REDIRECT_MODE_MAP["$_src"]="$_mode"
        REDIRECT_SITES_ARR+=("$_src")
        ALL_SITE_MAP["$_src"]=1
        ALL_SITES+=("$_src")
    done
fi

# TLS terminator proxy: TLS_TERMINATOR_PROXY=host:port:backend_host:backend_port[:proxy_protocol]
if [[ -n "${TLS_TERMINATOR_PROXY:-}" ]]; then
    IFS=',' read -ra _parts <<< "$TLS_TERMINATOR_PROXY"
    for _p in "${_parts[@]}"; do
        _p="$(trim_spaces "$_p")"
        [[ -z "$_p" ]] && continue
        IFS=':' read -ra _fields <<< "$_p"
        if [[ ${#_fields[@]} -lt 4 || ${#_fields[@]} -gt 5 ]]; then
            die "Malformed TLS_TERMINATOR_PROXY entry, expected host:port:backend_host:backend_port[:proxy_protocol]: $_p"
        fi
        _site="$(lower "$(trim_spaces "${_fields[0]}")")"
        _listen_port="$(trim_spaces "${_fields[1]}")"
        _backend_host="$(trim_spaces "${_fields[2]}")"
        _backend_port="$(trim_spaces "${_fields[3]}")"
        _pp=""
        if [[ ${#_fields[@]} -eq 5 ]]; then
            _pp="$(lower "$(trim_spaces "${_fields[4]}")")"
            [[ "$_pp" == "proxy_protocol" ]] || die "TLS_TERMINATOR_PROXY 5th field must be 'proxy_protocol'; got: $_pp (in $_p)"
        fi
        require_hostname "$_site" "TLS_TERMINATOR_PROXY"
        [[ "$_backend_host" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid backend host in TLS_TERMINATOR_PROXY: $_backend_host"
        is_positive_int "$_listen_port" || die "TLS_TERMINATOR_PROXY listen port must be a positive integer: $_listen_port"
        [[ "$_listen_port" -le 65535 ]] || die "TLS_TERMINATOR_PROXY listen port must be 1-65535: $_listen_port"
        [[ "$_listen_port" -eq 80 ]] && die "TLS_TERMINATOR_PROXY listen port 80 is forbidden (reserved for HTTP): $_p"
        is_positive_int "$_backend_port" || die "TLS_TERMINATOR_PROXY backend port must be a positive integer: $_backend_port"
        [[ "$_backend_port" -le 65535 ]] || die "TLS_TERMINATOR_PROXY backend port must be 1-65535: $_backend_port"
        [[ "${STATIC_SITE_MAP["$_site"]+isset}" == "isset" ]]     && die "$_site is configured in both STATIC_SITES and TLS_TERMINATOR_PROXY"
        [[ "${STATIC_PHP_SITE_MAP["$_site"]+isset}" == "isset" ]] && die "$_site is configured in both STATIC_PHP_SITES and TLS_TERMINATOR_PROXY"
        [[ "${PROXY_MAP["$_site"]+isset}" == "isset" ]]           && die "$_site is configured in both PROXY_SITES and TLS_TERMINATOR_PROXY"
        [[ "${REDIRECT_MAP["$_site"]+isset}" == "isset" ]]        && die "$_site is configured in both SITE_REDIRECTS and TLS_TERMINATOR_PROXY"
        [[ "${TLS_TERM_MAP["$_site"]+isset}" == "isset" ]]        && die "Duplicate TLS_TERMINATOR_PROXY frontend host: $_site"
        TLS_TERM_MAP["$_site"]="${_backend_host}:${_backend_port}"
        TLS_TERM_PORT_MAP["$_site"]="$_listen_port"
        [[ -n "$_pp" ]] && TLS_TERM_PP_MAP["$_site"]=1
        TLS_TERM_SITES_ARR+=("$_site")
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
# Also valid for STATIC_PHP_SITES entries.
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
        if [[ "${STATIC_SITE_MAP["$_site"]+isset}" != "isset" \
              && "${STATIC_PHP_SITE_MAP["$_site"]+isset}" != "isset" ]]; then
            die "STATIC_SITE_ROOTS entry for $_site has no matching STATIC_SITES or STATIC_PHP_SITES entry"
        fi
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
        [[ "${TLS_TERM_MAP["$_site"]+isset}" == "isset" ]] && die "BASIC_AUTH_FILES cannot be used with TLS_TERMINATOR_PROXY site: $_site (no HTTP layer)"
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

# Internal rewrites: SITE_REWRITES is newline-delimited; each line is
#   <host> <regex> <replacement> [last|break]
# whitespace-separated (so regex commas/colons and replacement slashes/queries
# don't collide with a delimiter). Rewrites are applied server-side with no
# redirect to the client. The replacement must be a path (leading '/') so nginx
# keeps the rewrite internal; an http(s):// target would silently become a 302.
# Only static and static-php sites are supported. Rules attach to the owning
# server block, so a rule may target a primary host or any of its aliases.
if [[ -n "${SITE_REWRITES:-}" ]]; then
    while IFS= read -r _line; do
        _line="$(trim_spaces "$_line")"
        [[ -z "$_line" ]] && continue
        read -r _rw_host _rw_pattern _rw_repl _rw_flag _rw_extra <<< "$_line"
        [[ -z "$_rw_host" || -z "$_rw_pattern" || -z "$_rw_repl" ]] \
            && die "Malformed SITE_REWRITES line, expected '<host> <regex> <replacement> [last|break]': $_line"
        [[ -n "$_rw_extra" ]] \
            && die "Too many fields in SITE_REWRITES line (regex and replacement must not contain whitespace): $_line"
        _rw_host="$(lower "$_rw_host")"
        require_hostname "$_rw_host" "SITE_REWRITES"
        [[ "${SERVER_NAME_OWNER["$_rw_host"]+isset}" == "isset" ]] \
            || die "SITE_REWRITES host must be a configured site or alias: $_rw_host"
        _rw_owner="${SERVER_NAME_OWNER["$_rw_host"]}"
        _rw_mode="$(site_mode "$_rw_owner")"
        case "$_rw_mode" in
            static|static-php) ;;
            *) die "SITE_REWRITES is only valid for static or static-php sites; $_rw_host resolves to $_rw_owner (mode=$_rw_mode)" ;;
        esac
        [[ "$_rw_repl" == /* ]] \
            || die "SITE_REWRITES replacement must be a path starting with '/' (got '$_rw_repl'); use SITE_REDIRECTS for external targets"
        [[ "$_rw_pattern" == *'"'* || "$_rw_repl" == *'"'* ]] \
            && die "SITE_REWRITES fields must not contain a double quote: $_line"
        [[ "$_rw_pattern" == *'\' || "$_rw_repl" == *'\' ]] \
            && die "SITE_REWRITES fields must not end with a backslash: $_line"
        _rw_flag="${_rw_flag:-last}"
        [[ "$_rw_flag" == "last" || "$_rw_flag" == "break" ]] \
            || die "SITE_REWRITES flag must be 'last' or 'break'; got: $_rw_flag (in $_line)"
        SITE_REWRITES_MAP["$_rw_owner"]="${SITE_REWRITES_MAP["$_rw_owner"]:-}    rewrite \"$_rw_pattern\" \"$_rw_repl\" $_rw_flag;"$'\n'
    done <<< "$SITE_REWRITES"
fi

DEFAULT_SITE="$(lower "$(trim_spaces "${DEFAULT_SITE:-}")")"
if [[ -n "$DEFAULT_SITE" ]]; then
    site_exists "$DEFAULT_SITE" || die "DEFAULT_SITE must match a configured primary site: $DEFAULT_SITE"
    [[ "${TLS_TERM_MAP["$DEFAULT_SITE"]+isset}" == "isset" ]] && die "DEFAULT_SITE cannot be a TLS_TERMINATOR_PROXY site: $DEFAULT_SITE"
fi

# HTTPS port overrides: HTTPS_PORT_OVERRIDE=host:port,...
if [[ -n "${HTTPS_PORT_OVERRIDE:-}" ]]; then
    IFS=',' read -ra _parts <<< "$HTTPS_PORT_OVERRIDE"
    for _p in "${_parts[@]}"; do
        _p="$(trim_spaces "$_p")"
        [[ -z "$_p" ]] && continue
        [[ "$_p" == *:* ]] || die "Malformed HTTPS_PORT_OVERRIDE entry, expected host:port: $_p"
        _host="$(lower "$(trim_spaces "${_p%%:*}")")"
        _port="$(trim_spaces "${_p#*:}")"
        require_hostname "$_host" "HTTPS_PORT_OVERRIDE"
        is_positive_int "$_port" || die "HTTPS_PORT_OVERRIDE port must be a positive integer: $_port"
        [[ "$_port" -le 65535 ]] || die "HTTPS_PORT_OVERRIDE port must be 1-65535: $_port"
        [[ "$_port" -eq 80 ]] && die "HTTPS_PORT_OVERRIDE port 80 is forbidden (reserved for HTTP): $_host:$_port"
        [[ "${SERVER_NAME_OWNER["$_host"]+isset}" == "isset" ]] \
            || die "HTTPS_PORT_OVERRIDE host must be a configured site or alias: $_host"
        _hp_primary="${SERVER_NAME_OWNER["$_host"]}"
        [[ "${TLS_TERM_MAP["$_hp_primary"]+isset}" == "isset" ]] \
            && die "HTTPS_PORT_OVERRIDE cannot be used with TLS_TERMINATOR_PROXY site $_hp_primary (host: $_host)"
        [[ "${HTTPS_PORT_MAP["$_host"]+isset}" == "isset" ]] && die "Duplicate HTTPS_PORT_OVERRIDE entry: $_host"
        HTTPS_PORT_MAP["$_host"]="$_port"
    done
    for _host in "${!HTTPS_PORT_MAP[@]}"; do
        _port="${HTTPS_PORT_MAP["$_host"]}"
        _primary="${SERVER_NAME_OWNER["$_host"]}"
        if [[ "${SITE_HTTPS_PORT["$_primary"]+isset}" == "isset" ]]; then
            [[ "${SITE_HTTPS_PORT["$_primary"]}" == "$_port" ]] \
                || die "Conflicting HTTPS_PORT_OVERRIDE ports for server block $_primary: ${SITE_HTTPS_PORT["$_primary"]} vs $_port (from $_host)"
        else
            SITE_HTTPS_PORT["$_primary"]="$_port"
        fi
    done
fi

# Validate TLS terminator port uniqueness and conflicts.
if [[ ${#TLS_TERM_SITES_ARR[@]} -gt 0 ]]; then
    declare -A _tls_term_ports_seen=()
    for _site in "${TLS_TERM_SITES_ARR[@]}"; do
        _port="${TLS_TERM_PORT_MAP["$_site"]}"
        if [[ "${_tls_term_ports_seen["$_port"]+isset}" == "isset" ]]; then
            die "TLS_TERMINATOR_PROXY listen port $_port is used by both ${_tls_term_ports_seen["$_port"]} and $_site (stream cannot share ports via SNI)"
        fi
        _tls_term_ports_seen["$_port"]="$_site"
        for _hp in "${!SITE_HTTPS_PORT[@]}"; do
            if [[ "${SITE_HTTPS_PORT["$_hp"]}" == "$_port" ]]; then
                die "TLS_TERMINATOR_PROXY listen port $_port ($_site) conflicts with HTTPS_PORT_OVERRIDE port on $_hp"
            fi
        done
        if [[ "$_port" == "443" ]]; then
            for _s in "${ALL_SITES[@]}"; do
                [[ "${TLS_TERM_MAP["$_s"]+isset}" == "isset" ]] && continue
                _sp="$(site_https_port "$_s")"
                if [[ "$_sp" == "443" ]]; then
                    die "TLS_TERMINATOR_PROXY listen port 443 ($_site) conflicts with site $_s on port 443"
                fi
            done
        fi
    done
    unset _tls_term_ports_seen
fi

CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-16m}"
PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-60s}"
PROXY_SEND_TIMEOUT="${PROXY_SEND_TIMEOUT:-60s}"
HSTS_MAX_AGE="${HSTS_MAX_AGE:-0}"
OCSP_STAPLING="${OCSP_STAPLING:-0}"
STATIC_FALLBACK_PAGES="${STATIC_FALLBACK_PAGES:-0}"
PROXY_RESOLVER="${PROXY_RESOLVER:-127.0.0.11}"
PROXY_RESOLVER_VALID="${PROXY_RESOLVER_VALID:-5s}"
REAL_IP_HEADER="${REAL_IP_HEADER:-X-Forwarded-For}"
LETSENCRYPT_RENEW_INTERVAL_SECONDS="${LETSENCRYPT_RENEW_INTERVAL_SECONDS:-43200}"
LE_RENEW_BEFORE_DAYS="${LE_RENEW_BEFORE_DAYS:-30}"

# PHP-related env (only meaningful on the -php image with PHP sites configured).
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-128M}"
PHP_MAX_EXECUTION_TIME="${PHP_MAX_EXECUTION_TIME:-30}"
PHP_FPM_PROFILE_RAW="${PHP_FPM_PROFILE:-M}"
PHP_FPM_PROFILE="$(upper "$(trim_spaces "$PHP_FPM_PROFILE_RAW")")"

if [[ "$PROXY_RESOLVER" != "default" ]]; then
    [[ "$PROXY_RESOLVER" =~ ^[A-Za-z0-9.:]+$ ]] || die "PROXY_RESOLVER must be an IP/hostname or 'default'; got: $PROXY_RESOLVER"
    is_safe_duration "$PROXY_RESOLVER_VALID" || die "PROXY_RESOLVER_VALID must look like 5s, 10s, or 30s; got: $PROXY_RESOLVER_VALID"
fi
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

is_php_memory_limit "$PHP_MEMORY_LIMIT" || die "PHP_MEMORY_LIMIT must look like 128M, 256M, 1G, or -1; got: $PHP_MEMORY_LIMIT"
is_non_negative_int "$PHP_MAX_EXECUTION_TIME" || die "PHP_MAX_EXECUTION_TIME must be a non-negative integer (0 = unlimited); got: $PHP_MAX_EXECUTION_TIME"
case "$PHP_FPM_PROFILE" in
    S|M|L|XL|XXL) ;;
    *) die "PHP_FPM_PROFILE must be one of S, M, L, XL, XXL (case-insensitive); got: $PHP_FPM_PROFILE_RAW" ;;
esac

# Derived values used by both nginx and PHP configs.
PHP_UPLOAD_LIMIT="$(nginx_size_to_php "$CLIENT_MAX_BODY_SIZE")"
PHP_REQUEST_TERMINATE_TIMEOUT=$((PHP_MAX_EXECUTION_TIME + 5))
FASTCGI_READ_TIMEOUT_SECONDS=$((PHP_MAX_EXECUTION_TIME + 30))

log "Sites: ${ALL_SITES[*]:-<none>}"

# Prepare static roots and placeholder content (for both static and static-php sites).
for _site in "${STATIC_SITES_ARR[@]}" "${STATIC_PHP_SITES_ARR[@]}"; do
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

generate_stream_config() {
    local site="$1"
    local conf="/etc/nginx/stream.d/nginx-auto-tls-proxy-${site}.conf"
    local listen_port="${TLS_TERM_PORT_MAP["$site"]}"
    local backend="${TLS_TERM_MAP["$site"]}"
    local var_slug="${site//[^a-zA-Z0-9]/_}"

    local resolver_lines=""
    local proxy_pass_line=""
    if [[ "$PROXY_RESOLVER" != "default" ]]; then
        resolver_lines="    resolver $PROXY_RESOLVER valid=$PROXY_RESOLVER_VALID;
    resolver_timeout 3s;"
        proxy_pass_line="    set \$backend_${var_slug} $backend;
    proxy_pass \$backend_${var_slug};"
    else
        if [[ "${OCSP_STAPLING:-0}" == "1" ]]; then
            resolver_lines="    resolver 1.1.1.1 1.0.0.1 valid=300s;
    resolver_timeout 5s;"
        fi
        proxy_pass_line="    proxy_pass $backend;"
    fi

    local pp_line=""
    [[ "${TLS_TERM_PP_MAP["$site"]+isset}" == "isset" ]] && pp_line="    proxy_protocol on;"

    local ocsp_lines=""
    if [[ "${OCSP_STAPLING:-0}" == "1" ]]; then
        ocsp_lines="    ssl_trusted_certificate /ssl/$site/chain.crt;
    ssl_stapling on;
    ssl_stapling_verify on;"
    fi

    cat > "$conf" <<NGINXEOF
server {
    listen $listen_port ssl;
    ssl_certificate     /ssl/$site/ssl.crt;
    ssl_certificate_key /ssl/$site/ssl.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_session_cache shared:STREAM_SSL_${var_slug}:1m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
$ocsp_lines

$resolver_lines
$proxy_pass_line
$pp_line
    proxy_timeout $PROXY_READ_TIMEOUT;
    proxy_connect_timeout $PROXY_SEND_TIMEOUT;
}
NGINXEOF

    log "Stream config written for $site (port=$listen_port backend=$backend)"
}

generate_site_config() {
    local site="$1"
    local conf="/etc/nginx/conf.d/nginx-auto-tls-proxy-${site}.conf"
    local server_names="$site"
    local alias
    local mode
    mode="$(site_mode "$site")"
    local site_port
    site_port="$(site_https_port "$site")"

    for alias in $(site_aliases "$site"); do
        server_names="$server_names $alias"
    done

    # HTTP-side redirect target. For redirect sites we go straight to the final
    # destination — no wasteful double 302 through https://<self>. For every
    # other mode the HTTP block 302s to the matching HTTPS server block on the
    # same host, as before.
    local http_redirect_target
    if [[ "$mode" == "redirect" ]]; then
        local _dst_host="${REDIRECT_MAP["$site"]}"
        local _dst_mode="${REDIRECT_MODE_MAP["$site"]}"
        local _dst_port _dst_port_suffix=""
        _dst_port="$(site_https_port "$_dst_host")"
        [[ "$_dst_port" != "443" ]] && _dst_port_suffix=":${_dst_port}"
        if [[ "$_dst_mode" == "deep" ]]; then
            http_redirect_target="https://${_dst_host}${_dst_port_suffix}\$request_uri"
        else
            http_redirect_target="https://${_dst_host}${_dst_port_suffix}/"
        fi
    else
        local _port_suffix=""
        [[ "$site_port" != "443" ]] && _port_suffix=":${site_port}"
        http_redirect_target="https://${site}${_port_suffix}\$request_uri"
    fi

    cat > "$conf" <<NGINXEOF
server {
    listen 80;
    server_name $server_names;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        try_files \$uri =404;
    }

    location / {
        return 302 $http_redirect_target;
    }
}

NGINXEOF

    if [[ "$mode" == "tls-terminator" ]]; then
        log "Config written for $site (mode=tls-terminator, HTTP-only for ACME/redirect)"
        return
    fi

    if [[ "$mode" == "redirect" ]]; then
        cat >> "$conf" <<NGINXEOF
server {
    listen $site_port ssl;
    http2 on;
    server_name $server_names;

    ssl_certificate     /ssl/$site/ssl.crt;
    ssl_certificate_key /ssl/$site/ssl.key;
$(nginx_ocsp_lines "$site")
$(nginx_hsts_line)
    include /etc/nginx/site-conf.d/$site/*.conf;

    location / {
$(nginx_auth_lines "$site")
        return 302 $http_redirect_target;
    }
}
NGINXEOF
        log "Config written for $site (mode=redirect -> $http_redirect_target)"
        return
    fi

    if [[ "$mode" == "proxy" ]]; then
        local proxy_url="${PROXY_MAP["$site"]}"
        local var_slug="${site//[^a-zA-Z0-9]/_}"
        local resolver_lines=""
        local proxy_pass_lines=""
        if [[ "$PROXY_RESOLVER" != "default" ]]; then
            local _proxy_var_url="${proxy_url%/}"
            resolver_lines="        resolver $PROXY_RESOLVER valid=$PROXY_RESOLVER_VALID;
        resolver_timeout 3s;"
            proxy_pass_lines="        set \$upstream_${var_slug} ${_proxy_var_url};
        proxy_pass \$upstream_${var_slug}\$request_uri;"
        else
            proxy_pass_lines="        proxy_pass $proxy_url;"
        fi
        cat >> "$conf" <<NGINXEOF
server {
    listen $site_port ssl;
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
$resolver_lines
$proxy_pass_lines
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
    elif [[ "$mode" == "static-php" ]]; then
        local site_root
        site_root="$(site_static_root "$site")"
        cat >> "$conf" <<NGINXEOF
server {
    listen $site_port ssl;
    http2 on;
    server_name $server_names;

    ssl_certificate     /ssl/$site/ssl.crt;
    ssl_certificate_key /ssl/$site/ssl.key;
$(nginx_ocsp_lines "$site")
    client_max_body_size $CLIENT_MAX_BODY_SIZE;
$(nginx_hsts_line)
    include /etc/nginx/site-conf.d/$site/*.conf;

    root "$site_root";
    index index.php index.html index.htm;
$(nginx_static_fallback_lines)

$(nginx_php_denylist)
$(nginx_rewrite_lines "$site")
    location / {
$(nginx_auth_lines "$site")
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
$(nginx_auth_lines "$site")
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_buffer_size       16k;
        fastcgi_buffers         8 16k;
        fastcgi_busy_buffers_size 32k;
        fastcgi_read_timeout      ${FASTCGI_READ_TIMEOUT_SECONDS}s;
    }
}
NGINXEOF
    else
        local site_root
        site_root="$(site_static_root "$site")"
        cat >> "$conf" <<NGINXEOF
server {
    listen $site_port ssl;
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
$(nginx_rewrite_lines "$site")
    location / {
$(nginx_auth_lines "$site")
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF
    fi

    log "Config written for $site (mode=$mode)"
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
        case "$mode" in
            proxy)
                target="${PROXY_MAP["$site"]}" ;;
            redirect)
                target="https://${REDIRECT_MAP["$site"]} (${REDIRECT_MODE_MAP["$site"]})" ;;
            tls-terminator)
                target="${TLS_TERM_MAP["$site"]} (stream/L4)" ;;
            *)
                target="$(site_static_root "$site")" ;;
        esac
        local _port_info=""
        local _sp; _sp="$(site_https_port "$site")"
        [[ "$_sp" != "443" ]] && _port_info=" port=$_sp"
        if [[ "$mode" == "tls-terminator" ]]; then
            _port_info=" stream-port=${TLS_TERM_PORT_MAP["$site"]}"
            [[ "${TLS_TERM_PP_MAP["$site"]+isset}" == "isset" ]] && _port_info="$_port_info proxy_protocol=on"
        fi
        local _rw_info=""
        if [[ "${SITE_REWRITES_MAP["$site"]+isset}" == "isset" ]]; then
            _rw_info=" rewrites=$(grep -c . <<< "${SITE_REWRITES_MAP["$site"]}")"
        fi
        log "  $site mode=$mode aliases=${aliases:-<none>} target=$target cert=$(cert_source "$site")${_port_info}${_rw_info}"
    done
}

# Render the FPM pool from PHP_FPM_PROFILE, plus the derived ini drop-in.
render_php_runtime_config() {
    [[ "${#STATIC_PHP_SITES_ARR[@]}" -gt 0 ]] || return 0

    local php_conf_d="/etc/nginx-auto-tls-proxy/php/conf.d"
    local fpm_pool_d="/etc/nginx-auto-tls-proxy/php/php-fpm.d"
    mkdir -p "$php_conf_d" "$fpm_pool_d"

    # Derived ini: ties memory/upload/timeout to the env vars.
    cat > "$php_conf_d/zz-derived.ini" <<INIEOF
; nginx-auto-tls-proxy entrypoint-derived PHP settings.
; Written at startup; overwritten on every container start.

memory_limit = $PHP_MEMORY_LIMIT
max_execution_time = $PHP_MAX_EXECUTION_TIME

; upload_max_filesize and post_max_size stay in lockstep with nginx's
; client_max_body_size so users can't get silent body truncation.
upload_max_filesize = $PHP_UPLOAD_LIMIT
post_max_size       = $PHP_UPLOAD_LIMIT
INIEOF

    # FPM pool config — values chosen by PHP_FPM_PROFILE.
    local pm pm_lines max_children start_servers min_spare max_spare max_requests
    case "$PHP_FPM_PROFILE" in
        S)
            pm=ondemand;  max_children=5;   max_requests=500;
            pm_lines="" ;;
        M)
            pm=dynamic;   max_children=20;  start_servers=2;  min_spare=1; max_spare=4;  max_requests=500
            pm_lines=$'pm.start_servers = 2\npm.min_spare_servers = 1\npm.max_spare_servers = 4' ;;
        L)
            pm=dynamic;   max_children=50;  start_servers=4;  min_spare=2; max_spare=10; max_requests=500
            pm_lines=$'pm.start_servers = 4\npm.min_spare_servers = 2\npm.max_spare_servers = 10' ;;
        XL)
            pm=dynamic;   max_children=100; start_servers=8;  min_spare=4; max_spare=20; max_requests=500
            pm_lines=$'pm.start_servers = 8\npm.min_spare_servers = 4\npm.max_spare_servers = 20' ;;
        XXL)
            pm=static;    max_children=200; max_requests=1000
            pm_lines="" ;;
    esac

    cat > "$fpm_pool_d/www.conf" <<FPMEOF
; nginx-auto-tls-proxy entrypoint-rendered FPM pool.
; Written at startup from PHP_FPM_PROFILE=$PHP_FPM_PROFILE.
; Overwritten on every container start. Add overrides as separate files
; in this directory (sorted lexically; later files override).

[www]
user  = nginx
group = nginx
listen = /run/php-fpm.sock
listen.owner = nginx
listen.group = nginx
listen.mode  = 0660

pm = $pm
pm.max_children = $max_children
pm.max_requests = $max_requests
pm.process_idle_timeout = 10s
${pm_lines}

request_terminate_timeout = ${PHP_REQUEST_TERMINATE_TIMEOUT}s

; Hardening: refuse to execute anything that isn't .php.
security.limit_extensions = .php

; Health probe used by /usr/local/bin/healthcheck.sh.
ping.path = /ping
ping.response = pong

; Worker stderr captured by FPM so 'docker logs' shows PHP errors.
catch_workers_output = yes
decorate_workers_output = no
clear_env = no
FPMEOF

    log "PHP_FPM_PROFILE=$PHP_FPM_PROFILE -> pm=$pm max_children=$max_children"
    log "PHP runtime: memory_limit=$PHP_MEMORY_LIMIT max_execution_time=${PHP_MAX_EXECUTION_TIME}s upload/post=$PHP_UPLOAD_LIMIT"
}

# Remove only configs generated by this image. Mounted custom snippets are left alone.
rm -f /etc/nginx/conf.d/nginx-auto-tls-proxy-*.conf
rm -f /etc/nginx/stream.d/nginx-auto-tls-proxy-*.conf
mkdir -p /etc/nginx/stream.d

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
    _ds_port="$(site_https_port "$DEFAULT_SITE")"
    _ds_port_suffix=""
    [[ "$_ds_port" != "443" ]] && _ds_port_suffix=":${_ds_port}"
    cat >> /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf <<NGINXEOF
        return 302 https://${DEFAULT_SITE}${_ds_port_suffix}\$request_uri;
NGINXEOF
else
    cat >> /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf <<'NGINXEOF'
        return 404;
NGINXEOF
fi

cat >> /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf <<'NGINXEOF'
    }
}
NGINXEOF

_has_port_443=0
for _site in "${ALL_SITES[@]}"; do
    [[ "${TLS_TERM_MAP["$_site"]+isset}" == "isset" ]] && continue
    [[ "$(site_https_port "$_site")" == "443" ]] && { _has_port_443=1; break; }
done
if [[ "$_has_port_443" == "1" || ${#ALL_SITES[@]} -eq 0 ]]; then
    cat >> /etc/nginx/conf.d/nginx-auto-tls-proxy-00-default.conf <<'NGINXEOF'

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
NGINXEOF
fi

generate_real_ip_config

if [[ ${#ALL_SITES[@]} -gt 0 ]]; then
    for _site in "${ALL_SITES[@]}"; do
        generate_site_config "$_site"
    done
else
    log "No sites configured."
fi

for _site in "${TLS_TERM_SITES_ARR[@]}"; do
    generate_stream_config "$_site"
done

render_php_runtime_config
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

PHP_FPM_PID=""
if [[ "${#STATIC_PHP_SITES_ARR[@]}" -gt 0 ]]; then
    log "Starting php-fpm (profile=$PHP_FPM_PROFILE)..."
    /usr/local/sbin/php-fpm --nodaemonize --force-stderr &
    PHP_FPM_PID=$!
fi

_shutdown() {
    log "Shutting down..."
    if [[ -n "$PHP_FPM_PID" ]]; then
        kill "$PHP_FPM_PID" 2>/dev/null || true
    fi
    kill "$NGINX_PID" 2>/dev/null || true
    if [[ -n "$PHP_FPM_PID" ]]; then
        wait "$PHP_FPM_PID" 2>/dev/null || true
    fi
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
if [[ -n "$PHP_FPM_PID" ]]; then
    wait -n "$NGINX_PID" "$PHP_FPM_PID"
    log "A supervised process exited; gracefully stopping the other before exiting."
    _shutdown
else
    wait "$NGINX_PID"
fi
