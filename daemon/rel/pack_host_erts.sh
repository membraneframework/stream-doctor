#!/usr/bin/env bash
# Packs the host's own OTP (the one `erl` on PATH runs) into the tarball layout
# Burrito's `custom_erts` expects:  otp-<ver>-<os>-<cpu>/{erts-X.Y.Z,lib}
# Needed when beam-machine has no prebuilt ERTS for the host OTP (29.0.6 -> 404)
# and on Linux, where its ERTS is a musl build that cannot load glibc NIFs.
# Only valid when the Burrito target equals the host.
set -euo pipefail
root=$(erl -noshell -eval 'io:format("~s",[code:root_dir()]), halt().')
otp=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().')
ver=$(cat "$root/releases/$otp/OTP_VERSION" 2>/dev/null || cat "$root/releases/"*/OTP_VERSION | head -1)
os=$(uname -s | tr 'A-Z' 'a-z'); cpu=$(uname -m); [ "$cpu" = arm64 ] && cpu=aarch64
name="otp-${ver}-${os}-${cpu}"
out_dir="${1:-$(dirname "$0")/../_build/custom_erts}"; mkdir -p "$out_dir"
out="$(cd "$out_dir" && pwd)/${name}.tar.gz"
erts_dir=$(basename "$(ls -d "$root"/erts-*)")
# Stage through symlinks and let tar -h follow them; works with both GNU and BSD tar.
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name"
ln -s "$root/$erts_dir" "$stage/$name/$erts_dir"
ln -s "$root/lib" "$stage/$name/lib"
echo "packing $root ($name) -> $out"
tar -C "$stage" -h -czf "$out" "$name"
ls -la "$out"; tar tzf "$out" | sed -n 1,3p
