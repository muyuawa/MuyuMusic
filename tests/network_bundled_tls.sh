#!/bin/bash
# Build the same pinned crypto/TLS HTTP sources for the host, then exercise
# production Objective-C against those static libraries (not Apple's libcurl).
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
mkdir -p .build
if ! mkdir .build/host-tls.lock 2>/dev/null; then
    echo 'Pinned TLS verification already running; wait for its existing build.' >&2
    exit 1
fi
trap 'rmdir .build/host-tls.lock' EXIT
task_cmake="${CMAKE:-/opt/local/bin/cmake}"
task_prefix="$task_root/.build/host-tls/prefix"
task_logs="$task_root/.build/host-tls/logs"
task_common=(-DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_C_FLAGS='-Os -DNDEBUG' -DCMAKE_INSTALL_PREFIX="$task_prefix" -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF)
test -f .deps/src/mbedtls-3.6.7/CMakeLists.txt
test -f .deps/src/curl-8.23.0/CMakeLists.txt
mkdir -p "$task_logs"
"$task_cmake" -S .deps/src/mbedtls-3.6.7 -B .build/host-tls/mbedtls "${task_common[@]}" -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF > "$task_logs/mbedtls-config.log" 2>&1
"$task_cmake" --build .build/host-tls/mbedtls --parallel 4 > "$task_logs/mbedtls-build.log" 2>&1
"$task_cmake" --install .build/host-tls/mbedtls > "$task_logs/mbedtls-install.log" 2>&1
"$task_cmake" -S .deps/src/curl-8.23.0 -B .build/host-tls/curl "${task_common[@]}" -DCMAKE_PREFIX_PATH="$task_prefix" -DCURL_USE_MBEDTLS=ON -DCURL_USE_OPENSSL=OFF -DCURL_USE_SECTRANSP=OFF -DCURL_USE_LIBPSL=OFF -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DHTTP_ONLY=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_USE_LIBSSH2=OFF -DUSE_LIBIDN2=OFF -DUSE_NGHTTP2=OFF -DENABLE_THREADED_RESOLVER=ON -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none > "$task_logs/curl-config.log" 2>&1
"$task_cmake" --build .build/host-tls/curl --parallel 4 > "$task_logs/curl-build.log" 2>&1
"$task_cmake" --install .build/host-tls/curl > "$task_logs/curl-install.log" 2>&1
export MC_NETWORK_PREFIX="$task_prefix"
export MC_EXPECT_MBEDTLS=1
tests/network_transport.sh
MC_NETWORK_SEARCH_ONLY=1 tests/network_live.sh
