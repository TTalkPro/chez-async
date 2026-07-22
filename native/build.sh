#!/usr/bin/env bash
# 构建 chez-async 的 C++ task 运行时（libchez-async-rt.so）。
# 用法：native/build.sh [Debug|RelWithDebInfo]（默认 RelWithDebInfo）
#
# 产物：native/build/libchez-async-rt.so
# Scheme 侧加载需 LD_LIBRARY_PATH 指向 native/build（或把 .so 装到系统库路径）。
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_type="${1:-RelWithDebInfo}"
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE="$build_type"
cmake --build "$here/build" --parallel
echo "✅ 构建完成：$here/build/libchez-async-rt.so"
