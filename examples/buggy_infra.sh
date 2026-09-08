#!/usr/bin/env sh
# audio content delayed by 200 ms, expect ~+200 ms drift
exec "$(dirname "$0")/infra.sh" -c:v copy -af 'adelay=200|200' -c:a aac -b:a 128k
