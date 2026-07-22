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
# Chez include（scheme.h）——pinned 零拷贝需要。从 scheme 可执行推导 boot 目录。
if [ -z "${CHEZ_INCLUDE:-}" ]; then
  schemebin="$(readlink -f "$(command -v scheme)")"
  CHEZ_INCLUDE="$(dirname "$schemebin")"        # …/lib/csv<ver>/<mt>/（含 scheme.h）
fi
cmake -S "$repo" -B "$repo/build/$mt" -DCMAKE_BUILD_TYPE="$build_type" \
      -DCMAKE_INSTALL_PREFIX="$landing" -DCHEZ_INCLUDE="$CHEZ_INCLUDE"
cmake --build "$repo/build/$mt" --parallel
cmake --install "$repo/build/$mt"
echo "✅ 构建完成：$landing/chez-async-rt.so"
