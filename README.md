# nginx-auto-tls-proxy

Self-contained nginx reverse proxy container with automatic per-site TLS, Let's Encrypt renewal, static hosting, optional PHP, and upstream proxying configured entirely with environment variables.

`nginx-auto-tls-proxy` is intentionally small: nginx, certbot, optional php-fpm, shell scripts, and generated nginx config. No dashboard, database, Docker socket discovery, or control plane.

## Features

- Static sites from `/sites/<domain>` or a custom mounted htdocs root.
- Reverse proxy sites with WebSocket upgrade headers.
- **Optional PHP-enabled static sites** via the separate `:<ver>-php` image tag.
- Per-site aliases and per-site SNI certificates.
- Self-signed fallback certificates on cold start.
- Optional Let's Encrypt issuance and renewal using HTTP-01 webroot challenges.
- HTTP to HTTPS redirects while preserving ACME challenge handling.
- Optional HSTS, OCSP stapling, basic auth files, real-ip trust, and proxy/body tuning.
- Dry-run mode and Docker healthcheck.

## Image Tags

Two image variants ship from one source tree:

| Tag                                          | Contents                                                           | When to use |
|---|---|---|
| `timorinne/nginx-auto-tls-proxy:<version>`   | nginx + certbot only                                               | Static and proxy sites without PHP. |
| `timorinne/nginx-auto-tls-proxy:<version>-php` | Same + `php-fpm` 8.5.x + curated extension set + `cgi-fcgi`     | Any deployment that needs `STATIC_PHP_SITES`. |
| `:latest` / `:latest-php`                    | Moving tags that always point at the most recent release pair.     | Convenience; pin a version for reproducible deploys. |

The two variants are always released in lockstep from the same git revision.

## Quick Start

Create `docker-compose.yaml`:

```yaml
services:
  nginx:
    image: timorinne/nginx-auto-tls-proxy:latest
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ssl_certs:/ssl
      - site_data:/sites
    environment:
      STATIC_SITES: "example.com"
      PROXY_SITES: "app.example.com:http://app:3000/"
      SITE_ALIASES: "example.com:www.example.com"
      LETSENCRYPT_EMAIL: "admin@example.com"
    restart: unless-stopped

  app:
    image: nginx:alpine

volumes:
  ssl_certs:
  site_data:
```

Run:

```bash
docker compose up -d
```

For local testing without Let's Encrypt:

```bash
docker compose -f dc/docker-compose.yaml up --build
```

## Try It Locally

The repository includes a demo stack with:

- `https://static.localhost` for a default static site
- `https://docs.localhost` for a static site using `STATIC_SITE_ROOTS`
- `https://app.localhost` for a proxied backend container

Run it:

```bash
docker compose -f dc/try/docker-compose.yaml up --build
```

Then open the URLs above. The certificates are self-signed, so your browser will show a warning.

Stop and remove demo volumes:

```bash
docker compose -f dc/try/docker-compose.yaml down -v
```

## Configuration

| Variable | Example | Purpose |
|---|---|---|
| `STATIC_SITES` | `example.com,docs.example.com` | Comma-separated static site hostnames. Defaults to `/sites/<domain>`. |
| `STATIC_PHP_SITES` | `blog.example.com,wiki.example.com` | Comma-separated PHP-enabled static site hostnames. See [PHP-Enabled Sites](#php-enabled-sites). **Requires the `:-php` image tag.** |
| `STATIC_SITE_ROOTS` | `docs.example.com:/htdocs/docs` | Optional `domain:absolute-path` overrides for selected static site roots (works for both `STATIC_SITES` and `STATIC_PHP_SITES`). |
| `PROXY_SITES` | `app.example.com:http://app:3000/` | Comma-separated `domain:upstream-url` reverse proxy mappings. |
| `SITE_ALIASES` | `example.com:www.example.com,old.example.com` | Aliases per primary site. Aliases inherit the primary's type (static, static-php, or proxy). Bare aliases extend the preceding `primary:alias` group. |
| `DEFAULT_SITE` | `example.com` | Optional target for unknown HTTP hostnames. May reference any primary from `STATIC_SITES`, `STATIC_PHP_SITES`, or `PROXY_SITES`. Unknown HTTPS SNI is still rejected. |
| `BASIC_AUTH_FILES` | `admin.example.com:/run/secrets/admin.htpasswd` | Optional mounted htpasswd files per site. |
| `CLIENT_MAX_BODY_SIZE` | `16m` | nginx request body limit for generated HTTPS servers. On `:-php` images this also drives PHP's `upload_max_filesize` and `post_max_size` so the two layers never disagree. |
| `PROXY_READ_TIMEOUT` | `60s` | Reverse-proxy read timeout. |
| `PROXY_SEND_TIMEOUT` | `60s` | Reverse-proxy send timeout. |
| `PHP_FPM_PROFILE` | `M` | One of `S`, `M`, `L`, `XL`, `XXL` (case-insensitive). FPM pool sizing profile; default `M`. See [PHP-Enabled Sites](#php-enabled-sites). |
| `PHP_MEMORY_LIMIT` | `128M` | PHP `memory_limit`; default `128M`. Format: integer + optional `K`/`M`/`G`, or `-1` for unlimited. |
| `PHP_MAX_EXECUTION_TIME` | `30` | PHP `max_execution_time` in seconds; default `30`. `0` = unlimited. FPM `request_terminate_timeout` and nginx `fastcgi_read_timeout` derive from this. |
| `HSTS_MAX_AGE` | `31536000` | Optional HSTS max-age. Disabled by default with `0`. |
| `STATIC_FALLBACK_PAGES` | `1` | Optionally creates simple `404.html` and `50x.html` files for static sites when missing. |
| `OCSP_STAPLING` | `1` | Optional OCSP stapling for real CA certificates. Disabled by default. |
| `REAL_IP_FROM` | `172.16.0.0/12` | Optional comma-separated trusted proxy ranges for nginx real-ip handling. |
| `REAL_IP_HEADER` | `X-Forwarded-For` | Header used with `REAL_IP_FROM`. |
| `LETSENCRYPT_EMAIL` | `admin@example.com` | Enables Let's Encrypt when set. |
| `LETSENCRYPT_DISABLE` | `1` | Temporarily disables Let's Encrypt even when `LETSENCRYPT_EMAIL` is configured. |
| `LETSENCRYPT_STAGING` | `1` | Uses the Let's Encrypt staging ACME server. |
| `LETSENCRYPT_RENEW_INTERVAL_SECONDS` | `43200` | Renewal loop interval. |
| `LE_RENEW_BEFORE_DAYS` | `30` | Existing LE certs are reused until this close to expiry. |
| `DRY_RUN` | `1` | Generates config, prints the site plan, runs `nginx -t`, and exits before starting nginx/certbot. |

## Static Sites

Static sites are rooted at `/sites/<domain>` by default. If the directory has no `index.html`, startup creates a small placeholder page so the site is immediately testable.

```yaml
environment:
  STATIC_SITES: "example.com,docs.example.com"
  STATIC_SITE_ROOTS: "docs.example.com:/htdocs/docs"
volumes:
  - site_data:/sites
  - ./docs-site:/htdocs/docs:ro
```

`docs.example.com` serves `/htdocs/docs`; `example.com` serves `/sites/example.com`.

## Reverse Proxy Sites

Proxy sites use `PROXY_SITES`:

```yaml
environment:
  PROXY_SITES: "app.example.com:http://app:3000/,api.example.com:http://api:8080/"
```

Generated proxy blocks include:

- `Host`
- `X-Forwarded-For`
- `X-Forwarded-Proto`
- `X-Forwarded-Port`
- `Upgrade`
- `Connection`

### Reverse Proxy Network Layouts

`PROXY_SITES` accepts any upstream URL that nginx can reach from inside the container. The right upstream address depends on where the backend service is running.

For backends in the same Docker Compose file, use Compose service names. Docker's default Compose network provides DNS for service names, so no extra network configuration is needed:

```yaml
services:
  nginx:
    image: timorinne/nginx-auto-tls-proxy:latest
    ports:
      - "80:80"
      - "443:443"
    environment:
      PROXY_SITES: "app.example.com:http://app:3000/,api.example.com:http://api:8080/"

  app:
    image: example/app

  api:
    image: example/api
```

For backends bound to host loopback addresses such as `127.0.0.1`, remember that container loopback normally means the container itself, not the Docker host. If you need `PROXY_SITES` to target host-local loopback services directly, run the proxy with host networking:

```yaml
services:
  nginx:
    image: timorinne/nginx-auto-tls-proxy:latest
    network_mode: host
    environment:
      PROXY_SITES: "app.example.com:http://127.0.0.1:3000/,api.example.com:http://127.0.0.2:8080/"
```

With `network_mode: host`, do not publish `ports`; nginx binds the host's port 80 and 443 directly. On Linux, other addresses in `127.0.0.0/8` can be useful when several local services should have separate loopback bind addresses.

For backends on arbitrary reachable addresses, use the reachable IP address or hostname directly. This works for LAN services, VPN or WireGuard peers, routed private networks, and other interfaces visible from the container:

```yaml
services:
  nginx:
    image: timorinne/nginx-auto-tls-proxy:latest
    ports:
      - "80:80"
      - "443:443"
    environment:
      PROXY_SITES: "nas.example.com:http://192.168.1.50:8080/,wg-app.example.com:http://10.8.0.23:3000/"
```

The container must have a route to those addresses, and any host or network firewall must allow the connection from Docker's bridge network or from the host when using host networking.

## TLS And Certificates

On startup, every configured primary site gets a certificate path:

```text
/ssl/<domain>/ssl.key
/ssl/<domain>/ssl.crt
/ssl/<domain>/chain.crt
```

If no certificate exists, a self-signed certificate is created with SANs for the primary domain and its aliases.

When `LETSENCRYPT_EMAIL` is set, certbot runs after nginx starts and uses `/var/www/acme` for HTTP-01 challenges. Certbot state is stored under `/ssl/letsencrypt`, so mount `/ssl` persistently.

Before enabling Let's Encrypt, every primary hostname and alias must resolve publicly to this container on port 80.

The PHP variant does not change cert behavior in any way — TLS, ACME, renewal, and SNI work identically across both image tags.

## PHP-Enabled Sites

The `:-php` image variant adds `php-fpm` so a subset of static sites can execute `.php` files.

```yaml
services:
  nginx:
    image: timorinne/nginx-auto-tls-proxy:latest-php
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ssl_certs:/ssl
      - ./blog-content:/sites/blog.example.com
    environment:
      STATIC_PHP_SITES: "blog.example.com"
      LETSENCRYPT_EMAIL: "admin@example.com"

volumes:
  ssl_certs:
```

### Behavior parity with `STATIC_SITES`

A site in `STATIC_PHP_SITES` is identical to a `STATIC_SITES` entry in every other respect: aliases, `STATIC_SITE_ROOTS`, `BASIC_AUTH_FILES`, ACME, HTTP-to-HTTPS redirects, and `DEFAULT_SITE` all work the same way. The **only** difference is that `*.php` files are executed via php-fpm instead of served as text.

**Aliases inherit their primary's type.** `SITE_ALIASES=blog.example.com:www.blog.example.com` with `blog.example.com` in `STATIC_PHP_SITES` makes `www.blog.example.com` execute PHP too — exactly as you'd expect.

**Mutual exclusivity.** A primary hostname may appear in exactly one of `STATIC_SITES`, `STATIC_PHP_SITES`, or `PROXY_SITES`. The entrypoint fails fast if a hostname is listed in two of them.

### Bundled PHP version

This image ships **PHP 8.5.x** from the Alpine `php85` track. Use it to match `composer.json` `php` constraints and plugin compatibility against `>=8.5`.

Operators who need a different track can rebuild from source with `--build-arg PHP_TRACK=84`. We may bump the default track in a future minor release; that is always a changelog-worthy event.

### Curated extension set

The image bundles these PHP extensions (in addition to PHP's built-in `json`, `Reflection`, `SPL`, `Core`, and `Zend OPcache`):

```
mbstring  intl  curl   xml      dom     xmlreader  xmlwriter  simplexml
gd        zip   fileinfo  session  tokenizer  pdo  pdo_mysql  pdo_pgsql
pdo_sqlite  mysqli  iconv  phar  ctype  bcmath  sodium  openssl
```

This covers WordPress, Drupal, Nextcloud, MediaWiki, phpBB, and most Composer-based PHP projects.

For extensions outside this set (`imap`, `ldap`, `redis`, `memcached`, `imagick`, `xdebug`, etc.), build a downstream image:

```dockerfile
FROM timorinne/nginx-auto-tls-proxy:1.x-php
RUN apk add --no-cache php85-pecl-imap php85-pecl-redis
```

### `PHP_FPM_PROFILE` — pool sizing

One env var, five profiles, no per-setting knobs. Default `M` should fit almost every personal or small-team deployment.

| Profile | `pm` | `max_children` | `start_servers` | `min_spare` | `max_spare` | `max_requests` | Peak RAM¹ | Realistic target |
|---|---|---|---|---|---|---|---|---|
| `S`       | `ondemand` |   5 | — | — | —  |  500 | ~250 MB  | 512 MB VPS, mostly-idle personal site |
| **`M`**¹  | `dynamic`  |  20 | 2 | 1 |  4 |  500 | ~1 GB    | 2 GB VPS, personal/small-team blog or WP |
| `L`       | `dynamic`  |  50 | 4 | 2 | 10 |  500 | ~2.5 GB  | 4–8 GB box, busy small-business site |
| `XL`      | `dynamic`  | 100 | 8 | 4 | 20 |  500 | ~5 GB    | 8–16 GB box, real traffic |
| `XXL`     | `static`   | 200 | — | — | —  | 1000 | ~10 GB   | 16+ GB dedicated, predictable peak |

¹ **Default.** `M` is sized so the typical operator never sets this variable.

² **Memory math caveat.** `~50 MB/process` is the average for a php-fpm worker with our curated extension set after opcache hits warm. WordPress with plugins trends higher (~80 MB); micro-frameworks lower (~30 MB). For accurate host sizing, multiply `max_children` by your *measured* per-worker RSS rather than the table's average.

Values are case-insensitive — `PHP_FPM_PROFILE=m` and `PHP_FPM_PROFILE=M` behave the same. An unknown value fails fast at startup with the list of accepted values.

### Timeout coordination

Three timeout layers fire in order so the lowest layer terminates the request cleanly before the higher layers declare the upstream dead:

| Layer | Value | Source |
|---|---|---|
| PHP `max_execution_time`        | `PHP_MAX_EXECUTION_TIME` (default `30`) | env var |
| FPM `request_terminate_timeout` | `PHP_MAX_EXECUTION_TIME + 5`            | derived |
| nginx `fastcgi_read_timeout`    | `PHP_MAX_EXECUTION_TIME + 30`           | derived |

All three move together when you bump `PHP_MAX_EXECUTION_TIME`. There's no separate "read timeout for PHP" knob because the only correct ordering is the one we derive.

### File-ownership contract (important)

Both nginx and php-fpm run as the `nginx` user, **UID 101 / GID 101**, in the container.

- Files mounted into `/sites/<domain>/` must be **readable** by UID 101.
- Any subdirectory PHP needs to **write** (WordPress `wp-content/uploads/`, Nextcloud `data/`, plugin caches) must be writable by UID 101.

On a typical Linux host:

```bash
sudo chown -R 101:101 ./blog-content
```

Or set ownership in a Dockerfile that builds the volume content.

There is no `PUID`/`PGID` runtime user-rewriting — the contract is intentionally simple. If your host filesystem can't accommodate `101:101`, run a one-shot init container that re-chowns the directory before the proxy starts.

### Stable image paths for overrides

```
/etc/nginx-auto-tls-proxy/php/conf.d/<file>.ini       # php.ini drop-ins
/etc/nginx-auto-tls-proxy/php/php-fpm.d/<file>.conf   # FPM pool overrides
```

These paths are **stable across PHP track bumps** (a symlink inside the image points them at the current Alpine `/etc/php<NN>/` tree). When we eventually move to track 86, your mounted overrides keep loading without changes.

**Mount individual files, not the directory.** Bind-mounting the whole `conf.d/` would shadow the project's baked `zz-defaults.ini` and break the hardening defaults.

Example override that disables opcache timestamp validation (production-mode opcache, edits require a php-fpm reload):

```yaml
volumes:
  - ./zz-prod.ini:/etc/nginx-auto-tls-proxy/php/conf.d/zz-prod.ini:ro
```

```ini
; zz-prod.ini
opcache.validate_timestamps = 0
```

### Strict routing — `.php` exists or 404

The proxy executes `*.php` files **only when the file actually exists on disk**. Non-existent paths return 404, never a fallthrough to `/index.php`. This is intentional: a front-controller rewrite that's correct for WordPress is wrong for Symfony, which is wrong for Drupal — there is no single default that gets all of them right.

Framework-specific rewrites go in `/etc/nginx/site-conf.d/<domain>/*.conf`.

#### Worked example — WordPress (end-to-end)

`docker-compose.yaml`:

```yaml
services:
  proxy:
    image: timorinne/nginx-auto-tls-proxy:latest-php
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ssl_certs:/ssl
      - ./wp-content:/sites/blog.example.com
      - ./nginx-wp.conf:/etc/nginx/site-conf.d/blog.example.com/wp.conf:ro
    environment:
      STATIC_PHP_SITES: "blog.example.com"
      SITE_ALIASES:     "blog.example.com:www.blog.example.com"
      LETSENCRYPT_EMAIL: "admin@example.com"
      CLIENT_MAX_BODY_SIZE: "64m"
      PHP_MEMORY_LIMIT: "256M"
      PHP_FPM_PROFILE:  "M"
    restart: unless-stopped
    depends_on:
      - db

  db:
    image: mariadb:11
    volumes:
      - db_data:/var/lib/mysql
    environment:
      MARIADB_DATABASE: wordpress
      MARIADB_USER: wp
      MARIADB_PASSWORD: change-me
      MARIADB_RANDOM_ROOT_PASSWORD: "1"
    restart: unless-stopped

volumes:
  ssl_certs:
  db_data:
```

`nginx-wp.conf` (mounted into the site-snippet directory):

```nginx
# WordPress pretty permalinks: non-existent paths fall through to /index.php.
# Placed in site-conf.d so it loads inside the HTTPS server block, before
# the strict location / { try_files $uri $uri/ =404; } the proxy generates.
location / {
    try_files $uri $uri/ /index.php?$args;
}
```

Initial setup (one-time):

```bash
sudo chown -R 101:101 ./wp-content     # so php-fpm can write wp-content/uploads
docker compose up -d
```

WordPress's installer will reach `db` over the Compose network. Point `WP_HOME` and `WP_SITEURL` at `https://blog.example.com`.

#### Worked example — Symfony (rewrite snippet)

Symfony's front controller lives at `public/index.php` and expects URLs to rewrite onto `/index.php/<request>` (with `$is_args$args` so query strings survive):

```nginx
# site-conf.d/api.example.com/symfony.conf
location / {
    try_files $uri /index.php$is_args$args;
}
```

The rewrite shape differs from WordPress (`/index.php$is_args$args` versus `/index.php?$args`) — that's why we don't ship a built-in default. Drupal, Laravel, and CodeIgniter follow the same pattern with their own variations; see each framework's docs.

### Security hardening (what's baked in)

The `:-php` image ships with defense-in-depth defaults so you don't have to know to set them:

- **Three-layer block on PHP execution outside intended paths.** nginx `try_files $uri =404`; php.ini `cgi.fix_pathinfo=0`; FPM pool `security.limit_extensions = .php`. A misconfiguration in any single layer doesn't yield code execution.
- **Production-mode php.ini defaults.** `expose_php=Off`, `display_errors=Off`, `log_errors=On`, `error_reporting=E_ALL & ~E_DEPRECATED & ~E_STRICT`, `session.cookie_httponly=On`, `session.cookie_secure=On`, `session.use_strict_mode=On`, `opcache.jit=Off`.
- **Curated sensitive-path denylist on every PHP site.** Returns 404 for `/.git/`, `/.env`, `/composer.json`, `/composer.lock`, `/package.json`, `/yarn.lock`, `*.bak`, `*.swp`, `*.orig`, `*~`, and any `.php` under `/vendor/` or `/node_modules/`.
- **HTTPS-only PHP.** PHP runs only over HTTPS — the port-80 server block only handles ACME challenges and 302-redirects everything else. `.php` requests on plain HTTP are 302'd to HTTPS before any FPM hand-off, so session cookies (`session.cookie_secure=On`) can't be exposed in clear.
- **Logs to stderr.** php-fpm error log and PHP `error_log` are symlinked to `/dev/stderr`, so `docker logs <container>` shows nginx + PHP errors interleaved.

If your app genuinely needs a denied path served (rare), override with a higher-priority `location` in `/etc/nginx/site-conf.d/<domain>/*.conf`.

### Failure mode: wrong image tag

If you set `STATIC_PHP_SITES` on the plain (non-`-php`) image, the container exits with:

```
[nginx-auto-tls-proxy] ERROR: STATIC_PHP_SITES is set but this image was built without PHP support; use the nginx-auto-tls-proxy:<ver>-php tag
```

Switch to the `-php` tag.

### Out of scope: databases

This image is responsible only for serving HTTP/HTTPS, TLS termination and renewal, and PHP execution against files in `/sites/`. PHP apps that need MySQL/MariaDB/Postgres bring their own — typically as a sibling service in `docker-compose.yaml` (as shown in the WordPress example) or as an external managed database. Persistent application state lives wherever the operator puts it (DB service, mounted volumes, external services).

## Custom nginx Snippets

Advanced per-site snippets can be mounted under:

```text
/etc/nginx/site-conf.d/<site>/*.conf
```

Generated config files are named `/etc/nginx/conf.d/nginx-auto-tls-proxy-*.conf`; other mounted `.conf` files are not removed on startup.

## Build

Local image (plain):

```bash
docker build -t nginx-auto-tls-proxy:local nginx-auto-tls-proxy
```

Local `:-php` image:

```bash
docker build --build-arg WITH_PHP=1 -t nginx-auto-tls-proxy:local-php nginx-auto-tls-proxy
```

Dry-run generated config:

```bash
docker run --rm \
  -e STATIC_SITES=example.local \
  -e DRY_RUN=1 \
  nginx-auto-tls-proxy:local
```

## Test

Two smoke scripts. The plain-image smoke verifies static hosting, custom roots, proxying, TLS fallback, redirects, ACME challenge serving, healthcheck, WebSocket proxy config, and the "plain image rejects `STATIC_PHP_SITES`" failure mode. The `-php` smoke reruns the static/proxy assertions on the `-php` image and adds PHP execution, version, FastCGI `/ping`, the "no PHP execution on plain `STATIC_SITES`" negative, and the hardening defaults.

```bash
tests/smoke.sh
tests/smoke-php.sh
```

`scripts/publish.sh` runs both before publishing.

## Publish To Docker Hub

Releases are cut by hand with `scripts/publish.sh`. The script runs both smoke tests, then builds two multi-arch images (`linux/amd64`, `linux/arm64`) — one with `WITH_PHP=1`, one without — and publishes four tags from one git revision:

| Tag | When |
|---|---|
| `:<version>`       | always |
| `:<version>-php`   | always |
| `:latest`          | unless `--no-latest` |
| `:latest-php`      | unless `--no-latest` |

```bash
docker login
scripts/publish.sh 0.1.0
```

The script is **ordered, not truly atomic**, by design. `docker buildx build --push` couples build and push for multi-arch manifests, so the two variants ship sequentially:

1. Smoke tests (plain + `-php`).
2. Pre-flight: registry check that neither `:<version>` nor `:<version>-php` already exists upstream.
3. Build & push `:<version>-php` (riskier — extra packages, more failure surface).
4. Build & push `:<version>` (plain).
5. Promote moving tags `:latest` and `:latest-php` via `buildx imagetools create` (manifest-only, no rebuild).
6. `git tag v<version>` and push.

The moving tags only flip when **both** versioned tags successfully pushed. If a build fails partway, the script's `--help` documents the recovery paths.

Useful flags:

- `--no-latest` — push only the versioned tags (use for back-port releases that must not move `latest` / `latest-php`).
- `--force` — skip the clean-tree, `main`-branch, and upstream-tag-presence guards (use sparingly).
- `--retag-latest-only` — re-promote `:latest` / `:latest-php` from existing versioned tags without rebuilding (recovery path for failed step 5). Requires `--force`.

Useful environment overrides:

- `IMAGE` — Docker Hub image name (default `timorinne/nginx-auto-tls-proxy`).
- `PLATFORMS` — buildx target platforms (default `linux/amd64,linux/arm64`).

The CI workflow at `.github/workflows/ci.yml` only runs the smoke tests on pushes and pull requests; it does not publish to Docker Hub.

## Repository Layout

```text
.github/workflows/         smoke-test CI workflow
dc/                        example docker-compose.yaml
dc/try/                    local demo stack
nginx-auto-tls-proxy/      Docker build context and runtime scripts
nginx-auto-tls-proxy/php/  baked php.ini and FPM master config (only used when WITH_PHP=1)
scripts/publish.sh         manual Docker Hub release helper
tests/smoke.sh             end-to-end Docker smoke test (plain image)
tests/smoke-php.sh         end-to-end Docker smoke test (-php image)
CHANGELOG.md               release notes
ROADMAP.md                 (local-only) design and maintenance notes
```

## License

MIT
