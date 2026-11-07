#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -n "${MC_NETWORK_PREFIX:-}" ]; then
    set -- -I"$MC_NETWORK_PREFIX/include" "$MC_NETWORK_PREFIX/lib/libcurl.a" "$MC_NETWORK_PREFIX/lib/libmbedtls.a" "$MC_NETWORK_PREFIX/lib/libmbedx509.a" "$MC_NETWORK_PREFIX/lib/libmbedcrypto.a" -framework SystemConfiguration
else
    set -- -lcurl
fi
out="${TMPDIR:-/tmp}/muyu-network-live"
clang -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations -ISources/Network -framework Foundation -framework Security "$@" Sources/Network/MCEAPI.m Sources/Network/MCHTTPClient.m Sources/Network/MCAPI.m tests/network_live.m -o "$out"
"$out"
