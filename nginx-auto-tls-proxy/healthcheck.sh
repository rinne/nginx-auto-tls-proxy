#!/bin/bash
set -uo pipefail

[[ -f /var/run/nginx.pid ]] || exit 1
kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null || exit 1

exec 3<>/dev/tcp/127.0.0.1/80 || exit 1
printf 'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
IFS= read -r status <&3 || exit 1
[[ "$status" == HTTP/* ]]
