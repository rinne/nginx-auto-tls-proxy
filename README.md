# nginx-auto-tls-proxy

Self-contained nginx reverse proxy container with automatic per-site TLS, Let's Encrypt renewal, static hosting, optional PHP, and upstream proxying configured entirely with environment variables.

`nginx-auto-tls-proxy` is intentionally small: nginx, certbot, optional php-fpm, shell scripts, and generated nginx config. No dashboard, database, Docker socket discovery, or control plane.

## Features

- Static sites from `/sites/<domain>` or a custom mounted htdocs root.
- Reverse proxy sites with WebSocket upgrade headers.
- Optional per-site **HTTP/3 (QUIC)** alongside HTTP/2.
- Long-lived streaming (SSE) endpoints with per-path buffering and timeout control.
- L4 TLS termination for non-HTTP backends via the nginx `stream` module.
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
| `TLS_TERMINATOR_PROXY` | `db.example.com:4343:postgres:5432` | Comma-separated `host:listen_port:backend_host:backend_port[:proxy_protocol]` entries for L4 TLS termination via the nginx `stream` module. Each entry needs its own listen port. See [TLS Terminator Proxies](#tls-terminator-proxies). |
| `SITE_REDIRECTS` | `old.example.com:example.com,api2.example.com:api.example.com:deep` | Comma-separated `source:destination[:mode]` 302-redirect rules. `mode` is `no-deep` (default) or `deep`. See [Redirect Sites](#redirect-sites). |
| `SITE_REWRITES` | `example.com ^/(\d+)$ /item.php?id=$1` | Newline-delimited internal rewrites (no client-visible redirect). One `<host> <regex> <replacement> [last\|break]` rule per line. See [Internal Rewrites](#internal-rewrites). |
| `SITE_ALIASES` | `example.com:www.example.com,old.example.com` | Aliases per primary site. Aliases inherit the primary's type (static, static-php, proxy, or redirect). Bare aliases extend the preceding `primary:alias` group. |
| `DEFAULT_SITE` | `example.com` | Optional target for unknown HTTP hostnames. May reference any primary from `STATIC_SITES`, `STATIC_PHP_SITES`, `PROXY_SITES`, or `SITE_REDIRECTS`. Unknown HTTPS SNI is still rejected. |
| `BASIC_AUTH_FILES` | `admin.example.com:/run/secrets/admin.htpasswd` | Optional mounted htpasswd files per site. |
| `SITE_ALLOWED_IPS` | `example.com:10.20.30.0/24,10.20.31.43,[2001:db8::/32];example2.com:127.0.0.1` | Optional per-site IP allow list enforced on the HTTPS server (non-matching clients get `403`). Semicolon-separated `host:ip[,ip...]` groups. IPv6 must be bracketed. See [IP Allow Lists](#ip-allow-lists). |
| `CLIENT_MAX_BODY_SIZE` | `16m` | nginx request body limit for generated HTTPS servers. On `:-php` images this also drives PHP's `upload_max_filesize` and `post_max_size` so the two layers never disagree. |
| `PROXY_READ_TIMEOUT` | `60s` | Reverse-proxy read timeout. |
| `PROXY_SEND_TIMEOUT` | `60s` | Reverse-proxy send timeout. |
| `PROXY_STREAM_PATHS` | `app.example.com:/events,api.example.com:/live:2h` | Comma-separated `host:/path-prefix[:timeout]` entries marking long-lived streaming endpoints on proxy sites. Disables response buffering and overrides the read/send timeouts for that prefix only. Timeout defaults to `10m`. See [Streaming Responses (SSE)](#streaming-responses-sse). |
| `PROXY_RESOLVER` | `127.0.0.11` | DNS resolver used for proxy and stream upstreams; default `127.0.0.11` (Docker's embedded DNS). `default` omits the resolver directive and falls back to nginx's startup-time resolution. See [Upstream DNS Resolution](#upstream-dns-resolution). |
| `PROXY_RESOLVER_VALID` | `5s` | How long nginx caches a resolved upstream address; default `5s`. Ignored when `PROXY_RESOLVER=default`. |
| `HTTPS_PORT_OVERRIDE` | `admin.example.com:4444` | Comma-separated `host:port` pairs serving specific hosts on a non-443 HTTPS port. Port `80` is rejected; `443` is a no-op. See [Non-Standard HTTPS Ports](#non-standard-https-ports). |
| `HTTP3_SITES` | `app.example.com,www.example.com` | Comma-separated hostnames to serve over HTTP/3 (QUIC) in addition to HTTP/2. `*` enables every eligible site; empty or unset disables HTTP/3 entirely. **Requires publishing the UDP port.** See [HTTP/3](#http3-quic). |
| `STRICT_SNI` | `1` | Reject connections whose SNI matches no configured site, on every HTTPS port. Default `1`. `0` restores the pre-0.10.0 behaviour where `HTTPS_PORT_OVERRIDE` ports served the first site instead. See [Unknown Hostnames](#unknown-hostnames-strict_sni). |
| `PHP_FPM_PROFILE` | `M` | One of `S`, `M`, `L`, `XL`, `XXL` (case-insensitive). FPM pool sizing profile; default `M`. See [PHP-Enabled Sites](#php-enabled-sites). |
| `PHP_MEMORY_LIMIT` | `128M` | PHP `memory_limit`; default `128M`. Format: integer + optional `K`/`M`/`G`, or `-1` for unlimited. |
| `PHP_MAX_EXECUTION_TIME` | `30` | PHP `max_execution_time` in seconds; default `30`. `0` = unlimited. FPM `request_terminate_timeout` and nginx `fastcgi_read_timeout` derive from this. |
| `HSTS_MAX_AGE` | `31536000` | Optional HSTS max-age. Disabled by default with `0`. |
| `STATIC_FALLBACK_PAGES` | `1` | Creates simple `404.html` and `50x.html` files for static sites when missing. Disabled by default with `0`. |
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

## Redirect Sites

`SITE_REDIRECTS` declares hostnames that exist only to **302-redirect** to another host. Useful for retiring old domain names, consolidating brands onto a canonical site, or pointing one hostname at another while keeping certs and ACME challenges working on the source.

Format: comma-separated `source:destination[:mode]`. Mode is `no-deep` (default) or `deep`.

| Example entry | Result |
|---|---|
| `old.example.com:example.com` | Any request to `https://old.example.com/anything` 302s to `https://example.com/` (drops the path). |
| `old.example.com:example.com:no-deep` | Same — `:no-deep` is the default; this form is just explicit. |
| `api2.example.com:api.example.com:deep` | Any request to `https://api2.example.com/foo/bar?x=1` 302s to `https://api.example.com/foo/bar?x=1` (preserves the path and query). |

```yaml
environment:
  SITE_REDIRECTS: "old.example.com:example.com,api2.example.com:api.example.com:deep"
```

Other behavior worth knowing:

- **Destination is a bare hostname.** Scheme is implicitly `https`. The destination need not be one of your own configured sites — it can be any external host.
- **Source still gets its own TLS cert** (self-signed at first, Let's Encrypt if enabled), so the 302 can be served over HTTPS with the correct SNI. Make sure the source's DNS resolves to this container before enabling Let's Encrypt for it.
- **ACME challenges still work** on the source — port 80's `/.well-known/acme-challenge/` is handled before the redirect, so certbot can renew normally.
- **Single hop, not two.** Plain HTTP requests to the source 302 directly to the final destination rather than first 302'ing to `https://<self>/` (the usual HTTP→HTTPS pattern). One redirect, not two.
- **Mutually exclusive primaries.** A hostname listed in `SITE_REDIRECTS` cannot also be in `STATIC_SITES`, `STATIC_PHP_SITES`, or `PROXY_SITES`. The entrypoint fails fast on overlap.
- **Aliases work.** `SITE_ALIASES=old.example.com:legacy.example.com` together with a `SITE_REDIRECTS` entry for `old.example.com` makes `legacy.example.com` redirect to the same destination.

## Internal Rewrites

`SITE_REWRITES` rewrites a request path **server-side**, with no redirect — the browser's address bar keeps showing the public URL while nginx internally serves a different path. This is the counterpart to [Redirect Sites](#redirect-sites): redirects change the client URL (302), rewrites do not.

Typical use: expose a short, pretty public URL like `https://example.com/ASDF-YUIO` while the real handler lives at `/do/something/cool?code=ASDF-YUIO`.

Unlike the other variables, `SITE_REWRITES` is **newline-delimited** (one rule per line), because regexes and replacement URLs routinely contain commas, colons, and slashes that would collide with a delimited grammar. Each line is whitespace-separated:

```
<host>  <regex>  <replacement>  [last|break]
```

```yaml
environment:
  SITE_REWRITES: |
    example.com  ^/([A-Z]{4}-[A-Z]{4})$  /do/something/cool?code=$1
    example.com  ^/p/(\d+)$               /products.php?id=$1
```

| Field | Meaning |
|---|---|
| `host` | A configured `STATIC_SITES`/`STATIC_PHP_SITES` primary or one of its aliases. The rule attaches to that site's server block. |
| `regex` | nginx location regex matched against the request URI. Capture groups are referenced as `$1`…`$9` in the replacement. |
| `replacement` | The internal target. **Must start with `/`.** Regex captures and a `?query` are allowed. |
| `flag` | Optional: `last` (default — re-run location matching, e.g. to reach `try_files` or the `.php` handler) or `break` (stop rewriting, stay in the current location). |

### Common patterns

Each row is a single `SITE_REWRITES` line and the public→internal mapping it produces. `$1`, `$2`, … are the regex capture groups.

| Goal | Rule | A request for… | …is served from |
|---|---|---|---|
| Short code → real handler | `shop.example.com  ^/([A-Z]{4}-[A-Z]{4})$  /do/something/cool?code=$1` | `/ASDF-YUIO` | `/do/something/cool?code=ASDF-YUIO` |
| Pretty product URL → query | `shop.example.com  ^/p/(\d+)$  /products.php?id=$1` | `/p/42` | `/products.php?id=42` |
| Hide the `.html` extension | `docs.example.com  ^/([a-z0-9-]+)$  /$1.html` | `/getting-started` | `/getting-started.html` |
| Date-based blog permalinks | `blog.example.com  ^/(\d{4})/(\d{2})/([a-z0-9-]+)$  /post.php?y=$1&m=$2&slug=$3` | `/2026/06/hello-world` | `/post.php?y=2026&m=06&slug=hello-world` |
| Versioned path → flat file | `api.example.com  ^/v1/status$  /status.json` | `/v1/status` | `/status.json` |
| Front-controller (framework) routing | `app.example.com  ^/(?!index\.php)(.*)$  /index.php?route=$1` | `/users/7/edit` | `/index.php?route=users/7/edit` |

The last row is the classic "send everything that isn't a real file to a single PHP entry point" pattern. On a `static-php` site, pair it with `try_files` so genuine static assets (CSS, images) are still served directly:

```yaml
# static-php site that routes all unknown paths through index.php
environment:
  STATIC_PHP_SITES: "app.example.com"
  SITE_REWRITES: |
    app.example.com  ^/(?!index\.php$)(?!.*\.[a-z0-9]+$).*$  /index.php
```

That regex rewrites to `/index.php` only when the path is **not** already `index.php` and does **not** end in a file extension, so `/style.css` and `/logo.png` keep being served as static files while `/dashboard` and `/users/7` reach the front controller. (For real frameworks you can usually skip `SITE_REWRITES` entirely and mount the framework's own `try_files` rule as a [custom snippet](#custom-nginx-snippets) — see the [Symfony example](#worked-example--symfony-rewrite-snippet). `SITE_REWRITES` shines for ad-hoc, per-path pretty URLs rather than whole-app routing.)

A complete example, end to end — a single site carrying **several rewrites at once**:

```yaml
services:
  proxy:
    image: timorinne/nginx-auto-tls-proxy:latest-php
    ports: ["80:80", "443:443"]
    volumes:
      - ./ssl:/ssl
      - ./shop:/sites/shop.example.com
    environment:
      STATIC_PHP_SITES: "shop.example.com"
      LETSENCRYPT_EMAIL: "admin@example.com"
      SITE_REWRITES: |
        shop.example.com  ^/([A-Z]{4}-[A-Z]{4})$  /redeem.php?code=$1
        shop.example.com  ^/p/(\d+)$              /products.php?id=$1
        shop.example.com  ^/u/([a-z0-9_]+)$       /profile.php?user=$1
        shop.example.com  ^/sale$                 /index.php?promo=summer
```

All four rules attach to the same `shop.example.com` server block, in the order written. The result:

| Public URL | Served internally from |
|---|---|
| `https://shop.example.com/ASDF-YUIO` | `/redeem.php?code=ASDF-YUIO` |
| `https://shop.example.com/p/42` | `/products.php?id=42` |
| `https://shop.example.com/u/timo` | `/profile.php?user=timo` |
| `https://shop.example.com/sale` | `/index.php?promo=summer` |

In every case the customer's address bar keeps showing the short public URL while the matching PHP script handles the request. Rules are evaluated **top to bottom**, and the first one whose regex matches wins (the `last` flag then re-runs location matching to reach the PHP handler). When two patterns could overlap, put the more specific rule first — e.g. a literal `^/sale$` before a broad `^/([a-z0-9-]+)$` catch-all — otherwise the broad rule would match first and the specific one would never fire.

### The rewritten query string is server-side only

This is the most common surprise, so it's worth stating plainly:

> A rewrite is **internal** — the browser's address bar keeps showing the original public URL (`/ASDF-YUIO`), **not** the rewrite target. The `?…=$1` query you add in the replacement exists only *inside nginx*. It is handed to a dynamic handler (PHP, CGI, a proxied backend) as the request's query args, but it **never appears in the browser URL**.

The practical consequence:

- **Dynamic target (`.php` on the `-php` image): works.** `buy.php` reads `$_GET['id']` from nginx's server-side query, so `^/(...)$ → /buy.php?id=$1` delivers the captured value.
- **Static target (`.html`) with client-side JavaScript: the query is invisible.** nginx serves the file bytes and ignores the `?id=…`; meanwhile the page's JavaScript reads `window.location.search`, which is empty because the browser URL is still `/ASDF-YUIO`. The script sees no `id` and reports it missing — even though visiting `/buy.html?id=ASDF-YUIO` directly works fine.

If you want a **static** page to know the captured value while keeping the pretty URL, read it from the path instead of a query string. The code is already in `window.location.pathname`:

```yaml
# rewrite to a bare static file — no query needed
SITE_REWRITES: |
  shop.example.com  ^/([A-Z0-9]{3}-[A-Z0-9]{3})$  /buy.html
```

```js
// in buy.html — read the short code from the path the browser still shows
const id = location.pathname.slice(1);            // "ASDF-YUIO"
if (!/^[A-Z0-9]{3}-[A-Z0-9]{3}$/.test(id)) { /* invalid code */ }
```

Use the `?…=$1` form only when the target is a server-side handler (`.php`, CGI, proxy) that reads the query from nginx. If you genuinely need the browser to display `/buy.html?id=…`, that is a 302 **redirect**, not an internal rewrite, and it gives up the short URL — `SITE_REWRITES` intentionally cannot do it (the replacement must be a path, which keeps the rewrite internal).

Other behavior worth knowing:

- **Internal only.** The replacement must be a path. An `http(s)://` target would make nginx emit a 302 instead — for that, use `SITE_REDIRECTS`.
- **Static and static-php only.** Proxy, redirect, and TLS-terminator sites reject `SITE_REWRITES`; the entrypoint fails fast.
- **Query strings.** nginx appends the original query args unless the replacement contains a `?`. The `?code=$1` form above therefore replaces the original query; end the replacement with `?` to drop args entirely, or add `$is_args$args` to append them. Remember this query is server-side only — see [The rewritten query string is server-side only](#the-rewritten-query-string-is-server-side-only).
- **Avoid loops.** If a rewrite target also matches a rule, nginx will cycle (capped at 10) and return `500`. Anchor your regexes (`^…$`) so targets don't re-match.
- **Aliases work.** A rule written against an alias is applied to the owning primary's server block, so it takes effect for the primary and every alias that shares it.
- **`$` in docker-compose.** Capture references are always `$1`…`$9`, which Compose passes through literally (it only substitutes `${name}`-style variables). If you ever place a `$` directly in front of a name — e.g. to forward the original query with `$is_args$args` — double it as `$$is_args$$args` so Compose doesn't try to interpolate it.

## IP Allow Lists

`SITE_ALLOWED_IPS` restricts who may reach a site over HTTPS at the nginx level. When a site has an allow list, nginx emits `allow` rules for the listed addresses followed by `deny all`, so any client whose IP is not covered gets a plain `403 Forbidden`. Sites with no entry are unaffected — the default is still "all clients allowed", so adding the variable is fully backwards-compatible.

```yaml
environment:
  SITE_ALLOWED_IPS: "intranet.example.com:10.20.30.0/24,10.20.31.43,192.168.0.0/16;admin.example.com:127.0.0.1,[2001:db8::/32]"
```

The value is a **semicolon-separated** list of `host:ip[,ip...]` groups; within each group the **comma-separated** tokens are the addresses allowed for that host. The example above parses as:

| Host | Allowed clients |
|---|---|
| `intranet.example.com` | `10.20.30.0/24`, `10.20.31.43`, `192.168.0.0/16` |
| `admin.example.com` | `127.0.0.1`, `2001:db8::/32` |

> **Note — this variable's separators are deliberately the opposite way round from the rest.** Everywhere else in this image a comma separates per-site entries (`STATIC_SITES`, `PROXY_SITES`, `SITE_ALIASES`, …). `SITE_ALLOWED_IPS` instead uses a **semicolon between sites** and reserves the **comma for the IP list of a single site**. Without that split, the comma before the next hostname would read as just another IP in the previous site's list (`…192.168.0.0/16,admin.example.com:…`), which is the one genuinely confusing case. So: **comma always means "another IP for the same site"; semicolon starts a new site.**

What each token may contain:

- **A single IPv4 address** — `10.20.31.43`
- **An IPv4 network** in CIDR form — `10.20.30.0/24`, `192.168.0.0/16`
- **A single IPv6 address**, bracketed — `[2001:db8::1]`
- **An IPv6 network** in CIDR form, bracketed — `[2001:db8::/32]`

IPv6 is **bracketed** so its colons never collide with the `host:ip` delimiter. Explicit-netmask forms (`1.2.3.0/255.255.255.0`) and ranges (`1.2.3.4-1.2.3.7`) are not supported — use CIDR.

Behavior and scope:

- **HTTPS only.** The allow list is emitted on the HTTPS server block. Plain HTTP on port 80 stays open so ACME (`/.well-known/acme-challenge/`) and the HTTP→HTTPS redirect keep working even for a locked-down site.
- **All site types except TLS-terminator.** Static, static-php, proxy, and redirect sites accept `SITE_ALLOWED_IPS`. TLS-terminator (L4 `stream`) sites have no HTTP layer to return a 403 and are rejected at startup.
- **Aliases work.** A rule written against an alias applies to the owning primary's server block, so it covers the primary and every alias that shares it.
- **Behind a trusted proxy.** nginx matches the connecting `$remote_addr`. If clients reach this container through an upstream load balancer, set [`REAL_IP_FROM`](#configuration) / `REAL_IP_HEADER` so the real client IP is matched instead of the proxy's.

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

### Upstream DNS Resolution

By default nginx resolves a `proxy_pass` hostname **once, when the configuration
loads**, and keeps that address forever. In Docker that is the wrong lifetime: a
backend container restarts, gets a new IP, and the proxy keeps sending traffic
to the old one until nginx itself is restarted.

This image avoids that by emitting the upstream through a variable together with
a `resolver`, so nginx re-resolves at request time:

```nginx
resolver 127.0.0.11 valid=5s;
set $upstream_app_example_com http://app:3000;
proxy_pass $upstream_app_example_com$request_uri;
```

`PROXY_RESOLVER` selects the resolver — `127.0.0.11` is Docker's embedded DNS and
is the default — and `PROXY_RESOLVER_VALID` (default `5s`) is how long a resolved
address is cached before it is looked up again. The same resolver is used for
`TLS_TERMINATOR_PROXY` stream upstreams.

Set `PROXY_RESOLVER=default` to omit the resolver directive entirely and use
nginx's built-in startup-time resolution instead:

```yaml
environment:
  PROXY_RESOLVER: "default"
```

That is the right choice when `127.0.0.11` does not exist — `network_mode: host`,
a non-Docker runtime — or when every upstream is a literal IP address and DNS is
not involved at all. Two consequences come with it:

- **Startup becomes strict.** If an upstream hostname does not resolve when nginx
  loads its configuration, nginx refuses to start. With a resolver configured the
  proxy starts anyway and returns `502` until the backend appears.
- **Addresses are never refreshed.** A backend that changes IP needs a restart of
  this container to be picked up.

## Streaming Responses (SSE)

A normal reverse-proxy response is buffered by nginx and bounded by
`PROXY_READ_TIMEOUT`. Both defaults are right for ordinary requests and wrong
for a stream that is meant to stay open: the client sees nothing until the
response ends — which for Server-Sent Events is never — and the connection is
cut after 60 seconds.

`PROXY_STREAM_PATHS` marks the endpoints where that trade should be reversed:

```yaml
environment:
  PROXY_SITES: "app.example.com:http://app:3000/"
  PROXY_STREAM_PATHS: "app.example.com:/events,app.example.com:/admapi/v1/live-stream:2h"
```

Each entry is `host:/path-prefix[:timeout]`. The timeout is optional and
defaults to `10m`; it accepts the same forms as `PROXY_READ_TIMEOUT` (`30s`,
`10m`, `1h`). For every entry the generated HTTPS server block gains one
location:

```nginx
location ^~ /events {
    # ... the same upstream and forwarded headers as location / ...
    proxy_buffering                    off;
    proxy_cache                        off;
    gzip                               off;
    proxy_read_timeout                 10m;
    proxy_send_timeout                 10m;
}
```

Everything else on the site is untouched. Ordinary responses keep their
buffering and the global timeout, which is why this is a per-path opt-in rather
than a per-site switch — turning buffering off for a whole site would slow every
normal response on it for the sake of one endpoint.

### Scope and interactions

- **Proxy sites only.** Static, static-php, redirect and TLS-terminator sites are
  rejected at startup.
- **A host may be a primary or an alias**; the location attaches to the owning
  server block and covers every name it serves.
- **`/` is not a valid path.** nginx treats `location ^~ /` and `location /` as
  the same location and refuses to start, so it is rejected up front — as are
  duplicate prefixes on one site.
- **`BASIC_AUTH_FILES` still applies.** The generated location carries its own
  `auth_basic`, so a streaming endpoint on an authenticated site stays
  authenticated. `SITE_ALLOWED_IPS` applies too — it is enforced at server scope.
- **Already using a `site-conf.d` snippet for this?** Remove it when you adopt
  the variable. Two definitions of the same location make nginx refuse to start.

### The `X-Accel-Buffering` alternative

nginx honours an `X-Accel-Buffering: no` response header from the upstream and
disables buffering for that one response. An application can therefore solve the
buffering half of this on its own, without any proxy configuration:

```
Content-Type: text/event-stream
X-Accel-Buffering: no
```

What it **cannot** do is extend the read timeout. A stream with that header set
still dies at `PROXY_READ_TIMEOUT` — 60 seconds by default — the moment it stays
idle that long. Use the header if you cannot change the proxy configuration; use
`PROXY_STREAM_PATHS` if you can, and both together do no harm.

### Send a heartbeat regardless

A well-behaved SSE upstream should emit a comment line every 20–30 seconds even
when it has nothing to say:

```
: ping

```

The timeout is a backstop for a wedged upstream, not a schedule to design
against. A heartbeat also keeps intermediate proxies, load balancers and NAT
tables from dropping an idle connection, none of which are governed by settings
in this image.

### Connection budget

Every open stream holds a connection slot for its entire lifetime, and a
**proxied** stream holds two — the client connection and the upstream
connection both count. `worker_connections` is `1024` in this image's
`nginx.conf` with no environment variable to change it, and because
`worker_processes` is `auto` that limit is *per worker* rather than a total,
with no guarantee that connections spread evenly across workers.

For a console with a handful of operators this is a non-issue. It is still a
shared resource: exhaust it and other sites on the same proxy stop accepting
connections. If you expect many concurrent streams, budget for it — making
`worker_connections` configurable is the natural follow-up when a real workload
needs it.

Note that HTTP/2 is already enabled on every generated HTTPS server block, so
browsers multiplex streams over one connection and the traditional
six-connections-per-origin limit does not apply.

## TLS Terminator Proxies

`PROXY_SITES` speaks HTTP: nginx parses the request, rewrites headers, and can
buffer. Some backends need none of that — a database, a message broker, an SMTP
or IMAP server, a game protocol. `TLS_TERMINATOR_PROXY` terminates TLS at the
edge and forwards the **decrypted TCP stream** to the backend through the nginx
`stream` module, with no HTTP parsing and no buffering:

```yaml
environment:
  TLS_TERMINATOR_PROXY: "db.example.com:4343:postgres:5432,mq.example.com:5671:rabbitmq:5672"
```

Each entry is `host:listen_port:backend_host:backend_port[:proxy_protocol]`.

### Every entry needs its own port

This is the one rule that surprises people. HTTPS server blocks all share port
443 and are told apart by SNI; the `stream` module has no such virtual hosting,
so **a stream site is identified by its listen port alone**. Two entries cannot
share a port, and startup refuses the configuration if they try. Ports are also
checked against `HTTPS_PORT_OVERRIDE` and against port 443 when any HTTP site is
using it.

Publish the ports you configure:

```yaml
ports:
  - "80:80"
  - "443:443"
  - "4343:4343"
  - "5671:5671"
```

### Client addresses

Because TLS is terminated here, the backend sees this container's address rather
than the client's. Append `proxy_protocol` as a fifth field to prepend a PROXY
protocol header to the connection:

```yaml
environment:
  TLS_TERMINATOR_PROXY: "db.example.com:4343:postgres:5432:proxy_protocol"
```

The backend must be configured to expect it — a backend that does not understand
PROXY protocol will treat the header as corrupt protocol data.

### Certificates still work normally

A TLS-terminator host is a site like any other: it gets its own SNI certificate,
its aliases land in the certificate SANs, and it is issued and renewed by Let's
Encrypt exactly as an HTTPS site is. That works because the host still gets a
plain **HTTP server block on port 80** for `/.well-known/acme-challenge/`, which
also 302-redirects everything else to `https://<host>:<listen_port>`.

### What does not apply

A stream block has no HTTP layer, so anything expressed in HTTP terms is refused
at startup rather than silently ignored:

| Variable | On a TLS-terminator site |
|---|---|
| `BASIC_AUTH_FILES` | Rejected — no HTTP layer to send `401` |
| `SITE_ALLOWED_IPS` | Rejected — no HTTP layer to return `403` |
| `HTTPS_PORT_OVERRIDE` | Rejected — the listen port is already explicit |
| `DEFAULT_SITE` | Rejected — cannot be a fallback for unknown HTTP hosts |
| `PROXY_STREAM_PATHS` | Rejected — there are no paths at layer 4 |

`PROXY_READ_TIMEOUT` and `PROXY_SEND_TIMEOUT` do apply, as the stream's
`proxy_timeout` and `proxy_connect_timeout`.

Generated stream configs live in `/etc/nginx/stream.d/nginx-auto-tls-proxy-<host>.conf`.

## Non-Standard HTTPS Ports

`HTTPS_PORT_OVERRIDE` serves selected hosts on an HTTPS port other than 443:

```yaml
environment:
  STATIC_SITES: "example.com"
  PROXY_SITES: "admin.example.com:http://admin:3000/"
  HTTPS_PORT_OVERRIDE: "admin.example.com:4444"
ports:
  - "80:80"
  - "443:443"
  - "4444:4444"
```

`example.com` stays on 443; `admin.example.com` is served **only** on 4444 and is
no longer reachable on 443. Several hosts may share one override port — unlike
`TLS_TERMINATOR_PROXY`, these are ordinary HTTPS server blocks and SNI still
tells them apart.

Details worth knowing:

- **Port 80 is rejected**, and `443` is accepted but does nothing.
- **The port propagates.** HTTP→HTTPS redirects for that host go to
  `https://host:4444/…`, and a `SITE_REDIRECTS` entry pointing at it redirects to
  its real port.
- **Aliases follow their primary.** An override written against an alias applies
  to the whole server block, and conflicting ports within one block are rejected.
- **ACME is unaffected.** Challenges are served on port 80 regardless, so Let's
  Encrypt works for hosts on non-standard ports — provided port 80 is reachable
  from the internet.
- **The 443 catch-all disappears** when no site uses 443. Normally an
  `ssl_reject_handshake` default server answers unknown SNI on 443; with every
  site moved off that port, nothing listens there at all.

## HTTP/3 (QUIC)

The image's nginx is built with `--with-http_v3_module` against OpenSSL 3.5, so
HTTP/3 needs no separate build. It is off by default and enabled per site:

```yaml
environment:
  STATIC_SITES: "example.com"
  PROXY_SITES: "app.example.com:http://app:3000/"
  HTTP3_SITES: "example.com,app.example.com"
ports:
  - "80:80"
  - "443:443"
  - "443:443/udp"     # REQUIRED - see below
```

`HTTP3_SITES` accepts a comma-separated host list, `*` for every eligible site,
or an empty value which is identical to leaving the variable out. A host may be
a primary or an alias and enables the whole server block. HTTP/2 is unaffected
and stays enabled everywhere — HTTP/3 is strictly additive.

### Publish the UDP port, or nothing happens

HTTP/3 runs over UDP. `- "443:443"` in Compose publishes **TCP only**, so
without the `/udp` line the QUIC listener is unreachable from outside the
container. Nothing breaks visibly: browsers try HTTP/3 once, get no answer, and
silently keep using HTTP/2 forever. If you enabled HTTP/3 and cannot tell
whether it works, check this first.

With `network_mode: host` there is nothing to publish and it works as-is.

### How a browser actually reaches HTTP/3

A browser cannot know a site speaks HTTP/3 until it is told, so every generated
HTTP/3 site advertises it on its ordinary HTTPS responses:

```
Alt-Svc: h3=":443"; ma=86400
```

The first request to a site is therefore always HTTP/2; subsequent ones may use
HTTP/3 for the next day. The advertised port always matches the port the site is
actually served on, including under `HTTPS_PORT_OVERRIDE`.

To confirm it works, use a client that supports HTTP/3 — note that many system
curl builds do not, so check `curl -V | grep HTTP3` first:

```bash
curl -I --http3-only https://example.com/
```

### Scope and rules

- **Not for TLS-terminator sites.** `TLS_TERMINATOR_PROXY` is layer 4 with no
  HTTP layer. Naming one in `HTTP3_SITES` is a startup error; `*` skips them.
- **`*` may not be combined** with explicit entries — it already means all.
- **TLS 1.3 only**, which the image already requires; HTTP/3 has no TLS 1.2 mode.
- **`reuseport` is handled for you.** nginx allows it on only one listener per
  port and QUIC needs it, so the generated catch-all owns it. Do not add a `quic`
  listener in a `site-conf.d` snippet — a second `reuseport` makes nginx refuse
  to start, and one without it makes QUIC handshakes fail intermittently.
- **Connection budget applies as it does for streaming** — see
  [Connection budget](#connection-budget).

## Unknown Hostnames (`STRICT_SNI`)

When a TLS connection arrives whose SNI matches no configured site — or carries
no SNI at all, as when you connect to a bare IP address — nginx has to decide
what to serve. Since `STRICT_SNI` defaults to `1`, the answer is: nothing. Every
HTTPS port gets a catch-all that refuses the handshake.

```yaml
environment:
  STRICT_SNI: "1"   # default
```

Port 443 has always behaved this way. What changed in 0.10.0 is that
`HTTPS_PORT_OVERRIDE` ports now behave the same. Previously they had no
catch-all, so an unknown hostname on such a port was served by whichever site's
config file sorted first — along with that site's certificate.

**This can break bare-IP access.** If you reach an admin site as
`https://10.0.0.5:4444/` with no hostname, that now fails. Use the hostname, or
opt out:

```yaml
environment:
  STRICT_SNI: "0"   # pre-0.10.0 behaviour
```

`STRICT_SNI=0` restores the old behaviour exactly: port 443 still rejects
unknown SNI, override ports fall through to the first site.

One wrinkle if you combine `STRICT_SNI=0` with `HTTP3_SITES`: only sites with
HTTP/3 enabled have a QUIC listener, so an unknown hostname falls through to the
first site over HTTP/2 but to the first *HTTP/3* site over HTTP/3 — which may be
a different site. Startup warns when this applies. The default `STRICT_SNI=1`
has no such asymmetry, since both protocols simply refuse.

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

Generated config files are named `/etc/nginx/conf.d/nginx-auto-tls-proxy-*.conf`, and `/etc/nginx/stream.d/nginx-auto-tls-proxy-*.conf` for `TLS_TERMINATOR_PROXY` sites; other mounted `.conf` files are not removed on startup.

## Running In Production

### Pre-flight checklist

Before the first start with `LETSENCRYPT_EMAIL` set:

- [ ] **Every primary hostname and alias resolves publicly to this container.**
      Certificate issuance fails otherwise, and failures count against Let's
      Encrypt rate limits.
- [ ] **Port 80 is reachable from the internet.** HTTP-01 challenges arrive
      there. It stays open even for sites behind `SITE_ALLOWED_IPS`, precisely
      so renewal keeps working.
- [ ] **`/ssl` is persisted** as a named volume or bind mount. Without it every
      restart discards certificates and re-requests them.
- [ ] **`/sites` is persisted** if you serve static content from the default root.
- [ ] **Every port you configure is published**, including `443:443/udp` for
      `HTTP3_SITES`, each `HTTPS_PORT_OVERRIDE` port, and each
      `TLS_TERMINATOR_PROXY` listen port.
- [ ] **`restart: unless-stopped`** is set.
- [ ] **Dry-run first:** `DRY_RUN=1` prints the site plan and runs `nginx -t`
      without starting anything or touching Let's Encrypt.

Then read the startup log once. The site plan lists every site with its mode,
aliases, target, certificate source and active features — the fastest way to
catch a hostname that silently fell into the wrong mode.

### What to back up

**`/ssl`, and nothing else is nearly as important.** It holds the per-site
certificates *and* certbot's own state under `/ssl/letsencrypt`. Losing it means
every certificate is re-requested from scratch, which risks running into Let's
Encrypt rate limits at exactly the moment your site is down.

`/sites` matters if it is the source of truth for your content rather than a
mount of something you already deploy elsewhere. Generated nginx configuration
needs no backup — it is rebuilt from environment variables on every start.

### Health and supervision

The container healthcheck asserts three things: the nginx master process is
alive, port 80 answers with an HTTP status line, and — only on `-php` images
with FPM running — that php-fpm replies `pong` on its FastCGI `/ping` endpoint.

If either supervised process exits, the entrypoint stops the other and the
container exits, so `restart: unless-stopped` gives you a clean restart rather
than a half-running container serving errors.

### Reading the logs

The access log carries the served hostname and the protocol, so one line tells
you which site answered and over what:

```
1.2.3.4 - - [31/Aug/2026:10:50:40 +0000] admin.example.com "GET /app.js HTTP/3.0" 200 595 "..." "..." "-"
                                         ^ $host                              ^ protocol
```

To see the protocol mix at a glance — the quickest check that HTTP/3 is really
being used:

```bash
docker compose logs proxy | grep -oE 'HTTP/[0-9]\.[0-9]"' | sort | uniq -c
```

`TLS_TERMINATOR_PROXY` sites log separately to `/var/log/nginx/stream-access.log`,
since layer-4 connections have no HTTP request line to record.

### Certificate renewal

With `LETSENCRYPT_EMAIL` set, a background loop runs `certbot renew` every
`LETSENCRYPT_RENEW_INTERVAL_SECONDS` (default 12 hours). Certificates are
renewed once they are within `LE_RENEW_BEFORE_DAYS` (default 30) of expiry. On
success a deploy hook copies the result to `/ssl/<domain>/` and reloads nginx —
no restart, no dropped connections.

Nothing needs scheduling on the host.

## Troubleshooting

### HTTP/3 is advertised but never used

Almost always the UDP port. `- "443:443"` in Compose publishes **TCP only**, and
the failure is silent: browsers try once, get nothing, and stay on HTTP/2.

```bash
# Is UDP published? Note the flag -- "443/udp" as a positional argument is a
# parse error, not a "no" answer.
docker compose port --protocol udp proxy 443

# Does HTTP/3 work from inside, bypassing publishing and any firewall?
docker compose exec proxy curl --http3-only -sS -o /dev/null \
  -w '%{http_version}\n' --resolve example.com:443:127.0.0.1 https://example.com/
```

If the inside test prints `3` but an outside test times out, the packets are
being dropped between the internet and the container: either the port is not
published, or a firewall is blocking inbound UDP 443. Cloud security groups
routinely allow TCP 443 while leaving UDP closed, since nothing needed it before
QUIC.

Note that most system `curl` builds have no HTTP/3 support — check with
`curl -V | grep HTTP3`. This image's own curl does, which is why the commands
above run inside the container.

### A site is still on a self-signed certificate

Check, in order: `LETSENCRYPT_EMAIL` is set and `LETSENCRYPT_DISABLE` is not
`1`; the hostname and all its aliases resolve publicly to this container; port
80 reaches it from the internet. Certbot output goes to the container log, and
its own logs persist under `/ssl/letsencrypt/logs`.

Use `LETSENCRYPT_STAGING=1` while debugging. Staging certificates are not
trusted by browsers, but the staging rate limits are far more forgiving.

### A proxy site returns 502

The upstream name is resolved at request time through `PROXY_RESOLVER`. A 502
usually means the upstream container is down or its name does not resolve — with
Compose, the service must share a network with the proxy. Confirm from inside:

```bash
docker compose exec proxy curl -sS -o /dev/null -w '%{http_code}\n' http://app:3000/
```

If you set `PROXY_RESOLVER=default`, nginx resolves once at startup instead, so
a backend that changed address needs this container restarted.

### Connection refused for a bare IP address or an unknown hostname

That is `STRICT_SNI`, which defaults to `1` and rejects connections whose SNI
matches no configured site. Use a configured hostname, or set `STRICT_SNI=0` to
restore the older behaviour. See [Unknown Hostnames](#unknown-hostnames-strict_sni).

### nginx refuses to start after adding `PROXY_STREAM_PATHS`

A mounted snippet under `/etc/nginx/site-conf.d/<site>/` already defines the same
location, and nginx rejects duplicates. The variable replaces that workaround —
remove the snippet.

### A site returns 403 to clients that should be allowed

`SITE_ALLOWED_IPS` matches the connecting address. Behind a load balancer that
is the balancer's address, not the client's — set `REAL_IP_FROM` to the trusted
proxy range so the forwarded address is used instead.

### A `.php` file downloads instead of executing

The plain image tag is running. `STATIC_PHP_SITES` requires `:<version>-php`;
the plain image refuses that variable at startup with an explicit message.

## Upgrading

Pull the new tag and recreate the container. Configuration is regenerated from
environment variables at every start, `/ssl` carries the certificates forward,
and nothing needs migrating.

```bash
docker compose pull && docker compose up -d
```

Note that a `ports:` change needs `docker compose up -d` to recreate the
container — `docker compose restart` will not pick it up.

**0.9.x → 0.10.0** changed one default. `STRICT_SNI=1` extends unknown-SNI
rejection to `HTTPS_PORT_OVERRIDE` ports, which previously served whichever site
sorted first. If you reach such a port by bare IP address, that now fails; set
`STRICT_SNI=0` to keep the old behaviour. Deployments without
`HTTPS_PORT_OVERRIDE` are unaffected.

## Versioning And Compatibility

This project follows [Semantic Versioning](https://semver.org/). From 1.0.0
onward, within the 1.x line:

- **Environment variable grammar is stable.** Existing variables keep their
  meaning and accepted syntax. New capabilities arrive as new variables, or as
  optional fields appended to an existing one.
- **Defaults do not change** in a way that alters observable behaviour. A change
  like 0.10.0's `STRICT_SNI` would require a major version.
- **Generated nginx configuration may change freely.** It is an implementation
  detail; only the behaviour it produces is a contract.
- **The `-php` variant tracks its PHP series.** A PHP major or minor bump is a
  breaking change for that tag and will not happen silently within 1.x.

Patch releases carry fixes and documentation. Minor releases add features and
remain backwards compatible. Both image variants are always released together
from one git revision.

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
