#!/usr/bin/env sh
# passthrough, no drift expected
exec "$(dirname "$0")/infra.sh" -c copy
