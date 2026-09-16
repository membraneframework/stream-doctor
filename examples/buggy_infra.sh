#!/usr/bin/env sh
# audio content delayed by 500 ms, expect ~+500 ms drift
exec "$(dirname "$0")/infra.sh" -c:v copy -af 'adelay=500|500' -c:a aac -b:a 128k
