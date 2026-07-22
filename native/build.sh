#!/usr/bin/env bash
# 直接用 cmake 构建 C++ task 运行时（不经 bake 的后备路径）。
# 用法：native/build.sh [Debug|RelWithDebInfo]（默认 RelWithDebInfo）
#
# 产物落 bake 约定位置：native/runtime/native/<machine-type>/chez-async-rt.so
# 首选 `bake runtime`；本脚本供无 bake 时的等价构建。
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/runtime"
build_type="${1:-RelWithDebInfo}"
mt="$(echo '(display (machine-type))' | scheme -q 2>/dev/null || echo ta6le)"
landing="$src/native/$mt"
cmake -S "$src" -B "$src/build/$mt" -DCMAKE_BUILD_TYPE="$build_type" \
      -DCMAKE_INSTALL_PREFIX="$landing"
cmake --build "$src/build/$mt" --parallel
cmake --install "$src/build/$mt"
echo "✅ 构建完成：$landing/chez-async-rt.so"
