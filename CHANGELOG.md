# Changelog

All notable changes to `nginx-auto-tls-proxy` are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-11-28

List variables may now span several lines. Pull and recreate the container;
before upgrading, check any value that already contains line breaks (see
Changed).

### Added

- Whitespace around the separators of every list variable is ignored, and line breaks count as whitespace: the `,` between entries, the `;` between `SITE_ALLOWED_IPS` groups, and the `:` between the fields of an entry. Long values can be written one entry per line, for example as a YAML block scalar (`PROXY_SITES: |`) in compose. Commas are still required between entries; a line break alone is not a separator. Only separators are trimmed: where only the first `:` of an entry separates (`PROXY_SITES`, `STATIC_SITE_ROOTS`, `BASIC_AUTH_FILES`, `HTTPS_PORT_OVERRIDE`, the host of `SITE_ALLOWED_IPS` and `PROXY_STREAM_PATHS`), the colons of the value, such as those of an upstream URL, are part of it, and whitespace inside a value is still invalid. The README has a new section, "Long values on several lines".

### Fixed

- Every list variable except `SITE_REWRITES` was read only up to its first line break, and the rest of the value was silently ignored. A value that started with a line break, as in `PROXY_SITES: |` followed by indented entries, configured no sites at all, without an error. For `SITE_ALLOWED_IPS` this failed open: the allow list of any group after the first line was dropped, so those sites accepted every client. The whole value is now read, so all 13 list variables (`STATIC_SITES`, `STATIC_PHP_SITES`, `PROXY_SITES`, `SITE_REDIRECTS`, `TLS_TERMINATOR_PROXY`, `SITE_ALIASES`, `STATIC_SITE_ROOTS`, `BASIC_AUTH_FILES`, `SITE_ALLOWED_IPS`, `HTTPS_PORT_OVERRIDE`, `PROXY_STREAM_PATHS`, `HTTP3_SITES`, `REAL_IP_FROM`) see every entry. Values on one line generate exactly the same configuration as in 1.0.4.

### Changed

- A value that contains line breaks is now read in full. If such a value worked under 1.0.x only because its later lines were ignored, those lines now take effect, or stop the container with an error if they are malformed (for example, entries on separate lines without a comma between them). Run the new image once with `DRY_RUN=1` to see the site plan before switching.
- `tests/smoke.sh` writes several of its list values as YAML block scalars, and checks that a multi-line value generates the same configuration as its one-line form and that a missing comma between lines is rejected.

## [1.0.4] - 2026-11-27

Security release for both tags, rebuilt with Alpine's latest package fixes.
Pull and recreate the container; there is nothing to configure.

### Security

- Both images ship **libxml2 2.13.9-r5** (1.0.3 carried 2.13.9-r3). Alpine fixed twelve flaws in it after 1.0.3 was built. Five of them are rated high: heap and stack buffer overflows that can lead to code execution when parsing crafted XML (CVE-2026-86138, CVE-2026-86140), an integer overflow in `xmlURIEscapeStr` (CVE-2026-86139), a heap overflow in XPointer evaluation (CVE-2026-86142), and an integer overflow in the output write callbacks (CVE-2026-86143). The others are denial-of-service bugs in XML catalogs, RelaxNG includes and regular expression parsing. As with 1.0.3, nginx does not load its XML modules here, so the plain image is not known to be exposed. The `-php` image's DOM, SimpleXML, XMLReader and XMLWriter extensions use libxml2, so PHP applications that handle XML from users were. CVE-2026-11979 and CVE-2026-1757 are in the `xmlcatalog` and `xmllint` tools, which the images do not contain.
- Both images ship **expat 2.11.0** (1.0.3 carried 2.10.0), fixing an out-of-bounds read in the unknown-encoding decoder (CVE-2026-124317) and improper handling of malformed UTF-16 (CVE-2026-134703), both rated medium. In these images expat is used by certbot's Python and by fontconfig, neither of which parses XML from clients. CVE-2026-128241 is in the `xmlwf` tool, which the images do not contain.

### Changed

- No changes to the code or configuration. nginx stays at 1.31.10 and the `-php` image at PHP 8.5.13; libxml2 and expat are the only packages that differ from 1.0.3.

## [1.0.3] - 2026-11-24

Security release for both tags. Pull and recreate the container; there is
nothing to configure.

### Security

- Both images ship **nginx 1.31.10** (released 2026-11-23; 1.0.2 carried 1.31.9):
  - CVE-2026-132779: a client could cause excessive CPU usage when the `ssl_early_data` directive is on. The image never turns it on, and nginx leaves it (and with it TLS 1.3 and QUIC 0-RTT) off by default, so only deployments that enable it in a custom snippet were exposed.
  - nginx could also hog CPU when it used SSL connections to backends, which `PROXY_SITES` entries with an `https://` upstream do.
- The Alpine packages that come with the base image are now brought up to date during the build. 1.0.2 shipped them as `nginx:alpine` had them, including **zlib 1.3.2**, which is affected by CVE-2026-85091 (heap overflow in non-blocking `gzwrite()`) and the other flaws fixed in zlib 1.4. None of the image's components is known to use zlib's affected gzip file functions (nginx compresses with the stream API), so this is a precaution rather than a known exposure. Both images now ship zlib 1.4 and zstd 1.6.0.
- Both images ship **libxml2 2.13.9-r3**, fixing CVE-2026-86144 (information disclosure, SSRF or denial of service when parsing untrusted XML; rated high). 1.0.2 carried 2.13.9-r2. nginx does not load its XML module here, but the `-php` image's DOM, SimpleXML and XMLReader extensions parse with libxml2, so PHP applications that read XML from users were exposed.
- The `-php` image's floor is raised to **PHP 8.5.13** (released 2026-11-19). 1.0.2-php already shipped 8.5.13, because Alpine had it on the day of the build, but its floor still allowed 8.5.12, so a rebuild from a lagging mirror could have gone back. 8.5.13 fixes eighteen vulnerabilities, among them in the components this image runs: PHP-FPM request smuggling through an unread request body (CVE-2026-129289) and an epoll use-after-free (CVE-2026-129291), remote code execution through sessions (CVE-2026-126714, CVE-2026-115560), and use-after-free flaws in the engine and in `ext/date` that can lead to remote code execution (CVE-2026-129474, CVE-2026-129496).

### Changed

- The Dockerfile runs `apk upgrade` before installing its own packages, so Alpine's security fixes reach the image with every build instead of waiting for the next rebuild of `nginx:alpine`. The base image pins nginx and its modules to exact versions, so the nginx.org build is never replaced by Alpine's own `nginx` package.
- `scripts/publish.sh` builds with `--no-cache` as well as `--pull`. When the base image had not changed since the previous release, cached layers would otherwise have reused that release's packages.
- `NGINX_MIN_VERSION` defaults to `1.31.10` and `PHP_MIN_VERSION` to `8.5.13`.
- CI uses `actions/checkout@v7`; v4 ran on the deprecated Node.js 20.

### Fixed

- Both smoke tests failed on Linux after every assertion had passed. The proxy writes its certificates into the tests' bind-mounted directories as root, the cleanup could not remove them as the invoking user, and under `set -e` that ended the script with status 1 and left a `.tmp-smoke.*` directory behind. This is why CI had never passed; Docker Desktop on macOS maps file ownership to the user and hides the problem. The cleanup now hands the files back through a short-lived container before removing them.

## [1.0.2] - 2026-11-20

Security release for both tags. Pull and recreate the container; there is
nothing to configure.

### Security

- Both images ship **nginx 1.31.9**, fixing four flaws that affect every earlier 1.31.x build, including the nginx 1.31.4 in 1.0.0 and the 1.31.8 in 1.0.1:
  - CVE-2026-123007 ("nginx2root"): memory corruption in HTTP/2 flow control that lets an unauthenticated client execute code. nginx rates it major, public reports rate it CVSS 9.2, and a working exploit has been published. Only HTTP/2 needs to be enabled, and this image enables it on every static, static-php, proxy and redirect site. Layer 4 `TLS_TERMINATOR_PROXY` sites do not speak HTTP/2.
  - CVE-2026-123633: use-after-free in HTTP/2.
  - CVE-2026-121810: use-after-free in HTTP/3, reachable on sites listed in `HTTP3_SITES`.
  - CVE-2026-123634: use-after-free in the resolver, reachable on proxy sites using the default `PROXY_RESOLVER`.
- nginx's suggested interim mitigation, disabling HTTP/2, is not available here, because the image has no setting for it. Updating is the fix. Running `apk upgrade` inside an older container does not help, because nginx comes from the base image rather than from Alpine's repositories.

### Added

- `ARG NGINX_MIN_VERSION` (default `1.31.9`) in the Dockerfile. The first build step reads the version from the base image's `nginx` binary and fails the build when it is lower, so a stale cached `nginx:alpine` can no longer produce an image with a known-vulnerable nginx. It complements `PHP_MIN_VERSION`: nginx is not installed through apk, so an apk constraint cannot guard it. The floor is raised with every nginx security release and never lowered. Builds overriding `NGINX_IMAGE` with another branch, such as `nginx:stable-alpine`, pass a floor from that branch, for example `1.30.7`.

### Changed

- `scripts/publish.sh` accepts a git tag `v<version>` that already exists, as long as it marks HEAD, so a release commit can be prepared and tagged before publishing. A tag on any other commit is still refused without `--force`. The script now pushes the tag at the end in both cases. Previously a pre-existing tag was refused, and with `--force` it was never pushed.
- Both images are built from the current `nginx:alpine` (Alpine 3.24 with nginx 1.31.9 at release time). No behaviour or configuration changes.

## [1.0.1] - 2026-10-22

Security release for the `-php` tag. Pull and recreate the container; there is
nothing to configure.

### Security

- The `-php` image ships **PHP 8.5.12**, fixing CVE-2026-109618 and CVE-2026-109619 ("php2shell"): two unauthenticated remote code execution flaws in PHP's request handling, rated CVSS 9.2 by the PHP security team and reported as exploited in the wild. 1.0.0-php carried PHP 8.5.9. Every PHP SAPI is affected, including php-fpm, so this image's nginx-side hardening does not mitigate them and updating is the only fix. Recreating the container restarts php-fpm, which the fix requires.

### Added

- `ARG PHP_MIN_VERSION` (default `8.5.12`) in the Dockerfile. `php85` and `php85-fpm` are now installed with an apk `>=` constraint, so a build against a base image whose repositories still carry an older PHP fails instead of silently producing a vulnerable image. Alpine's stable branches picked up the fixed package within a day of PHP's release, but not simultaneously: for some hours Alpine 3.23 still served php85 8.5.6 while 3.24 already had 8.5.12, so a build from a cached `nginx:alpine` on the older branch would have produced a vulnerable image without any warning. The floor is raised with every PHP security release and never lowered; operators overriding `PHP_TRACK` pass a matching `PHP_MIN_VERSION`.

### Changed

- `scripts/publish.sh` pulls `nginx:alpine` before running the smoke tests and passes `--pull` to both buildx invocations, so the tested and the published images always start from the registry's current base rather than a cached one. The README's local build commands gain `--pull` for the same reason.
- Both images are built from the current `nginx:alpine` (Alpine 3.24 with nginx 1.31.8 at release time; 1.0.0 was Alpine 3.24.1 with nginx 1.31.4). No behaviour or configuration changes.

### Fixed

- The smoke tests' HTTP/3 assertions ran the image's own curl, and Alpine's curl package (8.21 by August 2026) is built without HTTP/3. Both suites kept passing only because release builds tested against a months-old cached `nginx:alpine`; against a current base they fail at the first HTTP/3 probe. The probes now run from a Debian-based curl sidecar built from `tests/h3client/` and reach the proxy over the compose network, so the suites exercise the base that actually gets published.
- The README's HTTP/3 troubleshooting advice ran the inside test with the image's curl and stated that it supports HTTP/3. It now borrows a Debian curl in a throwaway container sharing the proxy's network namespace, and the HTTP/3 section says the image's curl cannot be used as a client.

## [1.0.0] - 2026-08-31

First stable release. **The image itself is unchanged from 0.10.0** — no runtime
file differs, so upgrading changes no behaviour. What 1.0.0 adds is a
compatibility commitment, verified documentation, and wider test coverage.

### Added

- A stated compatibility contract for the 1.x line: environment variable grammar stays stable, defaults do not change in ways that alter observable behaviour, generated nginx configuration remains an implementation detail, and the `-php` variant will not change its PHP series silently. A change like 0.10.0's `STRICT_SNI` default would now require a major version.
- Production documentation: a pre-flight checklist, what to back up and why (`/ssl` above all, since it holds certbot state as well as certificates), what the healthcheck actually asserts, how supervision and restart behave, how to read the access log including the protocol field, and how certificate renewal runs unattended.
- A symptom-oriented troubleshooting section covering HTTP/3 advertised but never used, certificates staying self-signed, proxy 502s, connections refused for bare IP addresses, `nginx` refusing to start after adopting `PROXY_STREAM_PATHS`, unexpected 403s behind a load balancer, and `.php` files downloading instead of executing.
- Upgrade notes, including the `STRICT_SNI` default change in 0.10.0 and the reminder that a `ports:` change needs `docker compose up -d` rather than `restart`.
- Smoke coverage for variables that previously had none: `DEFAULT_SITE`, `HSTS_MAX_AGE`, `STATIC_FALLBACK_PAGES`, `OCSP_STAPLING`, `REAL_IP_FROM`, `REAL_IP_HEADER` and `PROXY_RESOLVER_VALID`. `REAL_IP_FROM` is asserted behaviourally: the same request is refused without a forwarded address and served with one inside an allowed range, proving real-ip and `SITE_ALLOWED_IPS` interact correctly.
- A test exercising HTTP/3, a streaming path, basic auth and an IP allow list on a single site. Every feature was previously tested only in isolation.

### Fixed

- `dc/docker-compose.yaml`, the reference stack users copy, had drifted to roughly the 0.3.0 variable set — fourteen of the documented variables were missing, including every site type added since. It now lists all of them, grouped and commented, and publishes `443:443/udp` so HTTP/3 works when enabled.
- A README link pointed at a heading that does not exist, and two sections shared the heading "Scope and rules", making that anchor ambiguous.
- `STATIC_FALLBACK_PAGES` was the only boolean whose documented row did not state its default.

## [0.10.0] - 2026-08-29

### Added

- New `HTTP3_SITES` environment variable enabling **HTTP/3 (QUIC)** per site, alongside HTTP/2 rather than instead of it. Accepts a comma-separated host list, `*` for every eligible site, or an empty value which behaves exactly like the variable being absent. A host may be a primary or an alias and enables the owning server block.
- Each enabled site gains `listen <port> quic;`, `http3 on;`, and an `Alt-Svc: h3=":<port>"; ma=86400` response header — the advertisement without which no browser will ever attempt HTTP/3. The advertised port follows the port the site is actually served on, including under `HTTPS_PORT_OVERRIDE`.
- `*` skips `TLS_TERMINATOR_PROXY` sites silently, since they are layer 4 and have no HTTP layer; naming one explicitly is a startup error. Startup also rejects `*` combined with other entries, unknown hosts, and an nginx build without `--with-http_v3_module`.
- The single `reuseport` listener each port is allowed is placed on the generated catch-all. This is a correctness requirement, not a performance tweak: without it nginx's workers share one UDP socket, QUIC packets reach workers that do not hold the connection, and handshakes fail intermittently rather than outright.
- `tests/smoke.sh` gains a dedicated HTTP/3 stack asserting real behaviour — HTTP/3 actually negotiated on both port 443 and an override port, a site not listed refusing HTTP/3, `Alt-Svc` present with the correct port and absent where HTTP/3 is off, the UDP listener bound, and exactly one `reuseport` per port. HTTP/3 requests run inside the container because host curl builds frequently lack HTTP/3 support. `tests/smoke-php.sh` covers PHP executing over HTTP/3 on a `static-php` site.

### Changed

- **`STRICT_SNI`, new and defaulting to `1`, rejects connections whose SNI matches no configured site on every HTTPS port.** Port 443 has always done this. What changes is `HTTPS_PORT_OVERRIDE` ports, which previously had no catch-all at all: a request with an unknown hostname — or none, as when connecting to a bare IP address — was served by whichever site's config file sorted first, together with that site's certificate.
- **This can break bare-IP access to a site on an override port.** `https://<ip>:4444/` now fails the TLS handshake where it previously returned a site. Set `STRICT_SNI=0` to restore the previous behaviour exactly; deployments without `HTTPS_PORT_OVERRIDE` are unaffected.
- With `STRICT_SNI=0` and HTTP/3 both in use, an unknown hostname falls through to the first site over HTTP/2 but to the first HTTP/3-enabled site over HTTP/3, which may differ. Startup warns when this combination applies. The default has no such asymmetry.
- Generated configuration is byte-for-byte identical to 0.9.0 for any deployment that neither sets `HTTP3_SITES` nor uses `HTTPS_PORT_OVERRIDE`; with an override port the only difference is the added catch-all block.

## [0.9.0] - 2026-08-29

### Added

- New `PROXY_STREAM_PATHS` environment variable marking long-lived streaming endpoints — Server-Sent Events and anything else that must reach the client as it is produced — on reverse-proxy sites. Format: comma-separated `host:/path-prefix[:timeout]`, where the timeout is optional and defaults to `10m`. Each entry emits one `location ^~ <prefix>` on that site's HTTPS server block with `proxy_buffering off`, `proxy_cache off`, `gzip off`, and its own `proxy_read_timeout` / `proxy_send_timeout`.
- Without it, nginx's default `proxy_buffering on` holds the whole response until it ends — which for SSE is never — so the client sees nothing at all, and the global `PROXY_READ_TIMEOUT` cuts an idle stream after 60 seconds. Neither failure is visible from the application side.
- The opt-in is **per path, not per site**: ordinary responses on the same host keep their buffering and the global timeouts, so nothing else on the site pays for one streaming endpoint.
- The generated location repeats the site's `auth_basic` directives, because basic auth is emitted at location scope and would not otherwise apply — a streaming endpoint on a `BASIC_AUTH_FILES` site stays authenticated. `SITE_ALLOWED_IPS`, which is emitted at server scope, covers the new location automatically.
- A host may be a primary or an alias, resolving to the owning server block. Startup rejects non-proxy sites (static, static-php, redirect, TLS-terminator), unknown hosts, malformed timeouts, non-absolute paths, duplicate prefixes on one site, and `/` — which nginx would treat as a duplicate of `location /` and refuse to start on.
- `PROXY_STREAM_PATHS` is refused with a remediation message when `PROXY_RESOLVER=default` is combined with an upstream URL that carries a path of its own, a combination a prefix location cannot reproduce faithfully. Every other resolver and upstream combination is supported.
- The startup site plan reports a `stream-paths=<n>` count for each site carrying entries.
- `tests/smoke.sh` and `tests/smoke-php.sh` gain a dedicated streaming stack running with a deliberately short 2s global timeout and a 30s per-path override, asserting **behaviour** rather than config text: that the first event arrives within 2s (impossible with buffering on), that a later event past the global timeout still arrives, that an unlisted path on the same host still buffers and is still cut by the global timeout, and that a streaming endpoint on a basic-auth site returns 401 without credentials and streams with them. Config-shape and validation assertions accompany them, including a guard that no `proxy_buffering` or prefix location is emitted when the variable is unset.

### Changed

- Generated proxy server blocks are now written in two parts so the streaming locations can be appended after `location /`. Output is byte-for-byte identical to 0.8.0 when `PROXY_STREAM_PATHS` is unset, verified across every site type.

## [0.8.0] - 2026-06-30

### Added

- New `SITE_ALLOWED_IPS` environment variable for per-site IP allow lists enforced by nginx. Listed addresses get `allow` rules closed by `deny all`, so any client outside the list receives a plain `403 Forbidden`. Format is a **semicolon**-separated list of `host:ip[,ip...]` groups — the separators are deliberately inverted from the rest of the image so the comma can mean "another IP for the same site" without the next hostname reading as one more address.
- IPv4 addresses and CIDRs are written bare (`10.20.30.0/24`, `10.20.31.43`); IPv6 addresses and CIDRs must be bracketed (`[2001:db8::1]`, `[2001:db8::/32]`) so their colons never collide with the `host:ip` delimiter. Brackets are stripped before emission, since nginx's `allow` takes the bare address.
- Allow lists are emitted on the **HTTPS server block only**. Port 80 stays open so ACME (`/.well-known/acme-challenge/`) and the HTTP→HTTPS redirect keep working for a locked-down site and certificate renewal does not break.
- A rule may be written against a primary hostname or any of its aliases; groups accumulate on the owning server block. Static, static-php, proxy, and redirect sites are supported. TLS-terminator sites are rejected at startup because an L4 `stream` block has no HTTP layer with which to return a 403.
- Sites with no entry are unaffected — the default remains "all clients allowed" — so adding the variable is fully backwards-compatible.
- The startup site plan reports an `allowed-ips=<n>` count for each site carrying a list.
- `tests/smoke.sh` gains live 200/403 enforcement coverage, an assertion that a site without a list carries no `deny` directive, ACME and redirect passthrough on a locked site, and negative cases for an out-of-range CIDR, unbracketed IPv6, a malformed group, an empty IP list, an unknown host, and a TLS-terminator site. `tests/smoke-php.sh` asserts the same allow/deny emission on a static-php block.

## [0.7.0] - 2026-06-23

### Added

- New `SITE_REWRITES` environment variable for internal (server-side) URL rewrites. The client URL does not change — these are not 302 redirects. Rules are **newline-delimited**, one per line, as `<host> <regex> <replacement> [last|break]` separated by whitespace, so regex commas and colons and replacement slashes and query strings never collide with a delimiter.
- Each rule emits a quoted `rewrite "<regex>" "<replacement>" <flag>;` line at server scope, just before `location /`, on static and static-php server blocks. Quoting keeps regex metacharacters safe. The flag defaults to `last`.
- A rule may target a primary hostname or any of its aliases; it attaches to the owning server block and therefore covers the primary and every alias sharing it.
- Startup validation rejects the failure modes that would otherwise be silent: a replacement that is not a path starting with `/` (an `http(s)://` target would quietly become a 302 — `SITE_REDIRECTS` is the right tool for that), a host that is not a configured site or alias, a proxy / redirect / TLS-terminator target, an unknown flag, extra whitespace-separated fields, and fields containing a double quote or a trailing backslash.
- The startup site plan reports a `rewrites=<n>` count for each site carrying rules.
- `tests/smoke.sh` covers the emitted quoted rewrite line, a matching path served internally with a 200 (asserting no redirect), non-matching paths left untouched, alias-to-owner attachment with the `break` flag, and negatives for a non-path replacement, a proxy-site target, and an unknown host. `tests/smoke-php.sh` covers rewriting a pretty URL into a PHP script with the captured query string arriving intact.

## [0.6.0] - 2026-05-23

### Fixed

- Reverse-proxy sites resolved through `PROXY_RESOLVER` (the default path) dropped the request URI. The generated block emitted `proxy_pass $upstream_<site>;`, and because a `proxy_pass` given as a bare variable carries no URI component, every request reached the upstream at its root — `/api/users` was served as `/`. The generator now strips the trailing slash into the variable and appends the URI explicitly: `set $upstream_<site> <url>;` followed by `proxy_pass $upstream_<site>$request_uri;`. Deployments running `PROXY_RESOLVER=default` were never affected.

## [0.5.0] - 2026-05-23

### Added

- A dedicated `stream` log format and `/var/log/nginx/stream-access.log` for `TLS_TERMINATOR_PROXY` sites, recording the client address, `$ssl_server_name`, protocol, status, bytes in and out, session time, and upstream address. L4 traffic previously left no access-log trail at all.

### Changed

- The main `log_format` now includes `$host` between the timestamp and the request line. On a multi-site proxy the logs previously could not tell you which hostname served a request. Log parsers with fixed field positions need updating.

## [0.4.0] - 2026-05-23

### Added

- New `TLS_TERMINATOR_PROXY` environment variable for L4 TLS termination via the nginx `stream` module. Format: comma-separated `host:listen_port:backend_host:backend_port[:proxy_protocol]`. nginx terminates TLS and forwards the decrypted TCP stream to the backend with no HTTP parsing or buffering, which suits non-HTTP protocols and backends that must see a raw byte stream. The optional fifth field enables PROXY protocol so the backend still learns the client address.
- `nginx.conf` gains a `stream { include /etc/nginx/stream.d/*.conf; }` block and the image creates `/etc/nginx/stream.d/`. Generated stream configs follow the same `nginx-auto-tls-proxy-*.conf` naming, so mounted files are never removed on startup.
- Each TLS-terminator site needs a **unique** listen port: `stream` has no SNI-based virtual hosting, so ports cannot be shared the way HTTPS server blocks share 443. Startup rejects duplicate stream ports, collisions with `HTTPS_PORT_OVERRIDE`, and a stream site on 443 while any HTTP site also uses 443.
- TLS-terminator sites still get an HTTP server block in `conf.d/` so ACME challenges and the port-80 redirect keep working, and so certificates renew normally. They get no HTTPS block in `conf.d/`.
- New `HTTPS_PORT_OVERRIDE` environment variable, taking comma-separated `host:port` pairs, to serve specific hosts on a non-443 HTTPS port. Port 80 is forbidden and 443 is a no-op. Several hosts may share a port, and a host carrying an override is no longer served on 443. HTTP→HTTPS redirects and `SITE_REDIRECTS` destinations both carry the port through, and the `ssl_reject_handshake` catch-all on 443 is omitted entirely when no site uses that port.
- New `PROXY_RESOLVER` (default `127.0.0.11`, Docker's embedded DNS) and `PROXY_RESOLVER_VALID` (default `5s`) environment variables. Proxy upstreams are now emitted through a variable so nginx re-resolves them at request time with the given cache lifetime, instead of pinning the address at config load. A backend container that restarts with a new IP is picked up without restarting the proxy — previously it kept 502'ing until nginx was restarted. Setting `PROXY_RESOLVER=default` omits the resolver directive and restores nginx's built-in startup-time resolution.
- `tests/smoke.sh` gains DRY_RUN coverage for stream config generation (listen port, variable `proxy_pass`, `ssl_protocols`, the HTTP ACME block, alias handling, PROXY protocol, and the absence of an HTTPS block), for port overrides across static / proxy / redirect sites, for the omitted 443 catch-all, and for the resolver directives on proxy blocks — plus negatives for duplicate stream ports and a stream port colliding with `HTTPS_PORT_OVERRIDE`.

### Fixed

- `tests/smoke.sh` captured the built image ID after tearing down the compose stack, by which point compose state was gone and the DRY_RUN sub-checks ran against an empty image reference. The ID is now captured before teardown.
- DRY_RUN negative checks in `tests/smoke.sh` invoked the image's entrypoint directly, so the expected non-zero exit aborted the whole run under `set -e`. They now run via `--entrypoint bash` and assert on the error message instead.

## [0.3.0] - 2026-05-18

### Added

- New `SITE_REDIRECTS` environment variable for 302-redirect-only hostnames. Format: comma-separated `source:destination[:mode]` where `mode` is `no-deep` (default; always lands on `https://destination/`) or `deep` (preserves the original request URI). Redirect source hostnames still get their own SNI certs and serve ACME challenges normally so cert renewal keeps working.
- HTTP-side redirect for `SITE_REDIRECTS` sources is single-hop: requests on port 80 go directly to the final HTTPS destination instead of first 302'ing to `https://<self>/`.
- `tests/smoke.sh` gains positive coverage for both `no-deep` and `deep` redirect modes plus a single-hop HTTP-side assertion.

## [0.2.0] - 2026-05-18

### Added

- New `:-php` image variant bundling **PHP 8.5.x** (Alpine `php85` track) and a curated extension set (`mbstring`, `intl`, `curl`, `xml`, `dom`, `xmlreader`, `xmlwriter`, `simplexml`, `gd`, `zip`, `fileinfo`, `session`, `tokenizer`, `pdo`, `pdo_mysql`, `pdo_pgsql`, `pdo_sqlite`, `mysqli`, `iconv`, `phar`, `ctype`, `bcmath`, `sodium`, `openssl`; plus PHP-core `json` and built-in Zend `OPcache`).
- New `STATIC_PHP_SITES` environment variable for PHP-enabled static sites. Sites in `STATIC_PHP_SITES` behave identically to `STATIC_SITES` (aliases, custom roots, basic auth, ACME, redirects, `DEFAULT_SITE`) except that `*.php` files are executed via php-fpm.
- New `PHP_FPM_PROFILE` environment variable (`S` / `M` / `L` / `XL` / `XXL`, case-insensitive, default `M`) for FPM pool sizing.
- New `PHP_MEMORY_LIMIT` (default `128M`) and `PHP_MAX_EXECUTION_TIME` (default `30`) environment variables. The timeout drives derived values for FPM `request_terminate_timeout` and nginx `fastcgi_read_timeout` so the three layers stay in correct order.
- `CLIENT_MAX_BODY_SIZE` now also drives PHP `upload_max_filesize` and `post_max_size` on `-php` images, eliminating silent body truncation between the layers.
- Healthcheck probes php-fpm via `cgi-fcgi /ping` when FPM is running.
- New `scripts/publish.sh` four-tag matrix (`:<ver>`, `:<ver>-php`, `:latest`, `:latest-php`) with moving-tags-last failure model.
- New `tests/smoke-php.sh` covering PHP execution, version, FastCGI ping, hardening defaults, denylist, and the "no PHP execution on plain `STATIC_SITES`" negative.
- CI now runs both smoke scripts.

### Changed

- The Dockerfile gains `ARG WITH_PHP=0` and `ARG PHP_TRACK=85`. The plain image (`WITH_PHP=0`) is byte-identical in behavior to before.
- Stable image paths `/usr/local/sbin/php-fpm` and `/etc/nginx-auto-tls-proxy/php/` are created as symlinks on the `-php` image so user-mounted overrides survive future `PHP_TRACK` bumps.
- entrypoint.sh now supervises php-fpm alongside nginx when `STATIC_PHP_SITES` is non-empty; the container exits if either process dies (Docker `restart: unless-stopped` recovers cleanly).

### Security

- PHP execution on `-php` images is hardened with a three-layer chain: nginx `try_files $uri =404` + php.ini `cgi.fix_pathinfo=0` + FPM `security.limit_extensions=.php`. A misconfiguration in any single layer does not yield code execution.
- Curated denylist on every `STATIC_PHP_SITES` entry returns 404 for dotfiles, package manifests / lockfiles, `.env*`, editor backups, and any `.php` under `/vendor/` or `/node_modules/`.
- PHP runs only over HTTPS; `.php` requests on plain HTTP are 302-redirected to HTTPS before any FPM hand-off.

## [0.1.0] - 2026-05-18

Initial public release.
