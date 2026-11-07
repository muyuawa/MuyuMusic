#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -f Sources/Network/MCLXRuntime.m || { echo 'FAIL: embedded LX runtime is missing'; exit 1; }
bash scripts/build-quickjs.sh --host
clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -Wno-incomplete-implementation -Wno-deprecated-declarations -framework Foundation -framework Security -I.deps/src/mbedtls-3.6.7/include -I.build/deps/include -I.build/quickjs/include -ISources/Network tests/lx_runtime.m Sources/Network/MCLXRuntime.m .build/quickjs/host/libquickjs.a .build/quickjs/mbedtls/library/libmbedcrypto.a -lz -o .build/quickjs/lx_runtime
.build/quickjs/lx_runtime
