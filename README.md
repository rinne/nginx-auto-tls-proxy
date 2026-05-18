# nginx-auto-tls-proxy

Self-contained nginx reverse proxy container with automatic per-site TLS, Let's Encrypt renewal, static hosting, and upstream proxying configured entirely with environment variables.

`nginx-auto-tls-proxy` is intentionally small: nginx, certbot, shell scripts, and generated nginx config. No dashboard, database, Docker socket discovery, or control plane.

## Features

- Static sites from `/sites/<domain>` or a custom mounted htdocs root.
- Reverse proxy sites with WebSocket upgrade headers.
- Per-site aliases and per-site SNI certificates.
- Self-signed fallback certificates on cold start.
- Optional Let's Encrypt issuance and renewal using HTTP-01 webroot challenges.
- HTTP to HTTPS redirects while preserving ACME challenge handling.
- Optional HSTS, OCSP stapling, basic auth files, real-ip trust, and proxy/body tuning.
- Dry-run mode and Docker healthcheck.

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
| `STATIC_SITE_ROOTS` | `docs.example.com:/htdocs/docs` | Optional `domain:absolute-path` overrides for selected static site roots. |
| `PROXY_SITES` | `app.example.com:http://app:3000/` | Comma-separated `domain:upstream-url` reverse proxy mappings. |
| `SITE_ALIASES` | `example.com:www.example.com,old.example.com` | Aliases per primary site. Bare aliases extend the preceding `primary:alias` group. |
| `DEFAULT_SITE` | `example.com` | Optional target for unknown HTTP hostnames. Unknown HTTPS SNI is still rejected. |
| `BASIC_AUTH_FILES` | `admin.example.com:/run/secrets/admin.htpasswd` | Optional mounted htpasswd files per site. |
| `CLIENT_MAX_BODY_SIZE` | `16m` | nginx request body limit for generated HTTPS servers. |
| `PROXY_READ_TIMEOUT` | `60s` | Reverse-proxy read timeout. |
| `PROXY_SEND_TIMEOUT` | `60s` | Reverse-proxy send timeout. |
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

## Custom nginx Snippets

Advanced per-site snippets can be mounted under:

```text
/etc/nginx/site-conf.d/<site>/*.conf
```

Generated config files are named `/etc/nginx/conf.d/nginx-auto-tls-proxy-*.conf`; other mounted `.conf` files are not removed on startup.

## Build

Local image:

```bash
docker build -t nginx-auto-tls-proxy:local nginx-auto-tls-proxy
```

Dry-run generated config:

```bash
docker run --rm \
  -e STATIC_SITES=example.local \
  -e DRY_RUN=1 \
  nginx-auto-tls-proxy:local
```

## Test

The smoke test builds a temporary image and verifies static hosting, custom roots, proxying, TLS fallback, redirects, ACME challenge serving, healthcheck, and WebSocket proxy config.

```bash
tests/smoke.sh
```

## Publish To Docker Hub

Releases are cut by hand with `scripts/publish.sh`. The script runs the smoke test, builds a multi-arch image (`linux/amd64`, `linux/arm64`), pushes `<version>` and `latest` to the same digest, and creates and pushes the matching `v<version>` git tag.

```bash
docker login
scripts/publish.sh 0.1.0
```

Useful flags:

- `--no-latest` — push only the versioned tag (use for back-port releases that must not move `latest`).
- `--force` — skip the clean-tree and `main`-branch guards (use sparingly for hotfix branches).

Useful environment overrides:

- `IMAGE` — Docker Hub image name (default `timorinne/nginx-auto-tls-proxy`).
- `PLATFORMS` — buildx target platforms (default `linux/amd64,linux/arm64`).

The CI workflow at `.github/workflows/ci.yml` only runs the smoke test on pushes and pull requests; it does not publish to Docker Hub.

## Repository Layout

```text
.github/workflows/      smoke-test CI workflow
dc/                     example docker-compose.yaml
dc/try/                 local demo stack
nginx-auto-tls-proxy/   Docker build context and runtime scripts
scripts/publish.sh      manual Docker Hub release helper
tests/smoke.sh          end-to-end Docker smoke test
CHANGELOG.md            release notes
ROADMAP.md              roadmap and maintenance direction
```

## License

MIT
