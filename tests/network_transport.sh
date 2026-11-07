#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -n "${MC_NETWORK_PREFIX:-}" ]; then
    set -- -I"$MC_NETWORK_PREFIX/include" "$MC_NETWORK_PREFIX/lib/libcurl.a" "$MC_NETWORK_PREFIX/lib/libmbedtls.a" "$MC_NETWORK_PREFIX/lib/libmbedx509.a" "$MC_NETWORK_PREFIX/lib/libmbedcrypto.a" -framework SystemConfiguration
else
    set -- -lcurl
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/muyu-network-transport.XXXXXX")
server_pid=''
cleanup() { if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi; rm -rf "$work"; }
trap cleanup EXIT INT TERM
cat > "$work/cert.conf" <<'CONFIG'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=localhost
[ext]
subjectAltName=DNS:localhost
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment
CONFIG
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/cert.conf" >/dev/null 2>&1
python3 tests/network_transport_server.py "$work/cert.pem" "$work/key.pem" "$work/port" &
server_pid=$!
i=0
while [ ! -f "$work/port" ]; do i=$((i+1)); if [ "$i" -gt 50 ]; then exit 1; fi; sleep 0.1; done
clang -std=c11 -D_DARWIN_C_SOURCE -pthread -ISources/Playback -c Sources/Playback/MCPlaybackCore.c -o "$work/playback.o"
clang -fobjc-arc -fblocks -ISources/Playback -Wall -Wextra -Wno-deprecated-declarations -ISources/Network -framework Foundation "$@" Sources/Network/MCEAPI.m Sources/Network/MCHTTPClient.m tests/network_transport.m Sources/Playback/MCAudioSource.m Sources/Playback/MCAudioPolicy.m "$work/playback.o" -o "$work/tests"
MC_TEST_CA="$work/cert.pem" MC_TEST_BASE="https://localhost:$(cat "$work/port")" "$work/tests"
clang -fobjc-arc -fblocks -ISources/Playback -Wall -Wextra -Wno-deprecated-declarations -ISources/Network -framework Foundation "$@" Sources/Network/MCEAPI.m Sources/Network/MCHTTPClient.m tests/network_http.m Sources/Playback/MCAudioSource.m Sources/Playback/MCAudioPolicy.m "$work/playback.o" -o "$work/http-tests"
MC_TEST_CA="$work/cert.pem" MC_TEST_BASE="https://localhost:$(cat "$work/port")" MC_TEST_HTTP_BASE="http://localhost:$(cat "$work/port.http")" "$work/http-tests"
