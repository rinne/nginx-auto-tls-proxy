#!/bin/bash
set -uo pipefail

# --- nginx liveness + responsiveness ---
[[ -f /var/run/nginx.pid ]] || exit 1
kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null || exit 1

exec 3<>/dev/tcp/127.0.0.1/80 || exit 1
printf 'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
IFS= read -r status <&3 || exit 1
[[ "$status" == HTTP/* ]] || exit 1
exec 3<&- 3>&-

# --- php-fpm responsiveness (only when FPM was started) ---
if [[ -f /run/php-fpm.pid ]]; then
    kill -0 "$(cat /run/php-fpm.pid)" 2>/dev/null || exit 1
    [[ -S /run/php-fpm.sock ]] || exit 1
    SCRIPT_NAME=/ping \
    SCRIPT_FILENAME=/ping \
    REQUEST_METHOD=GET \
    QUERY_STRING= \
        cgi-fcgi -bind -connect /run/php-fpm.sock 2>/dev/null \
        | grep -q '^pong$' || exit 1
fi

exit 0
