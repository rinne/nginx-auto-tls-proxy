# Changelog

All notable changes to `nginx-auto-tls-proxy` are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
