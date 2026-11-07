#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_version=2026-06-04
task_archive=vendor/archives/quickjs-2026-06-04.tar.xz
echo 'b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a  vendor/archives/quickjs-2026-06-04.tar.xz' | shasum -a 256 -c -
test -f ".deps/src/quickjs-$task_version/quickjs.c" || tar -xf "$task_archive" -C .deps/src
task_src="$PWD/.deps/src/quickjs-$task_version"
mkdir -p .build/quickjs/include
cp "$task_src/quickjs.h" .build/quickjs/include/
# Single-queue interpreter has no shared-memory threads. Omit Atomics wait APIs
# (clock_gettime is unavailable on iOS 7); retain stack checks and interruption.
sed 's/^#define CONFIG_ATOMICS$/\/\* Atomics disabled for bounded single-queue host. *\//' "$task_src/quickjs.c" > .build/quickjs/quickjs.c.tmp
if ! cmp -s .build/quickjs/quickjs.c.tmp .build/quickjs/quickjs.c; then mv .build/quickjs/quickjs.c.tmp .build/quickjs/quickjs.c; else rm .build/quickjs/quickjs.c.tmp; fi
for task_target in host armv7; do
  if [[ "${1:-}" == --host && "$task_target" == armv7 ]]; then continue; fi
  mkdir -p ".build/quickjs/$task_target"
  task_cc=(clang)
  if [[ "$task_target" == armv7 ]]; then task_cc=(scripts/cc-ios); fi
  task_objects=()
  for task_name in quickjs dtoa libregexp libunicode cutils; do
    task_obj=".build/quickjs/$task_target/$task_name.o"
    task_input="$task_src/$task_name.c"
    if [[ "$task_name" == quickjs ]]; then task_input=.build/quickjs/quickjs.c; fi
    if [[ ! -f "$task_obj" || "$task_input" -nt "$task_obj" || "$0" -nt "$task_obj" ]]; then
      "${task_cc[@]}" -std=gnu11 -Os -fvisibility=hidden -fno-strict-aliasing -D_GNU_SOURCE -DCONFIG_VERSION='"2026-06-04"' -I"$task_src" -c "$task_input" -o "$task_obj"
    fi
    task_objects+=("$task_obj")
  done
  ar rcs ".build/quickjs/$task_target/libquickjs.a" "${task_objects[@]}"
done
# RSA uses the same audited Mbed TLS as the transport; host tests need its host archive.
if [[ ! -f .build/quickjs/mbedtls/library/libmbedcrypto.a ]]; then
  task_cmake="${CMAKE:-$(command -v cmake || printf '%s' /opt/local/bin/cmake)}"
  "$task_cmake" -S .deps/src/mbedtls-3.6.7 -B .build/quickjs/mbedtls -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DCMAKE_BUILD_TYPE=MinSizeRel > .build/quickjs/mbedtls-config.log 2>&1
  "$task_cmake" --build .build/quickjs/mbedtls --parallel 4 > .build/quickjs/mbedtls-build.log 2>&1
fi
