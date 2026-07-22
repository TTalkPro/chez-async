#!/usr/bin/env bash
# 直接用 cmake 构建 C++ task 运行时（无 bake 时的等价后备）。
# 用法：native/build.sh [Debug|RelWithDebInfo]（默认 RelWithDebInfo）
#
# 产物落 bake 约定位置：<repo>/native/<machine-type>/chez-async-rt.so
# 首选 `bake runtime`；构建入口是仓库根的 CMakeLists.txt。
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_type="${1:-RelWithDebInfo}"
mt="$(echo '(display (machine-type))' | scheme -q 2>/dev/null || echo ta6le)"
landing="$repo/native/$mt"
cmake -S "$repo" -B "$repo/build/$mt" -DCMAKE_BUILD_TYPE="$build_type" \
      -DCMAKE_INSTALL_PREFIX="$landing"
cmake --build "$repo/build/$mt" --parallel
cmake --install "$repo/build/$mt"
echo "✅ 构建完成：$landing/chez-async-rt.so"
