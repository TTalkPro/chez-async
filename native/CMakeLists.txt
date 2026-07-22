cmake_minimum_required(VERSION 3.20)

project(chez-async-runtime
  DESCRIPTION "chez-async 的 Task-based I/O 运行时（移植自 skiff src/runtime）"
  LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# system libuv（chez-async 已依赖 libuv.so.1；用 pkg-config 找，退回手动）
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(LIBUV libuv)
endif()

# S1:vendor 自 skiff src/runtime @ 93e0fd6 的 task 运行时（纯 C++/libuv）。
# task.hpp/net.hpp/runtime.hpp 是头文件；编译单元是 runtime.cpp + rt_ffi.cpp。
add_library(chez-async-rt SHARED
  runtime/runtime.cpp
  runtime/rt_ffi.cpp)

target_include_directories(chez-async-rt PRIVATE ${LIBUV_INCLUDE_DIRS})

if(LIBUV_LIBRARIES)
  target_link_libraries(chez-async-rt PRIVATE ${LIBUV_LIBRARIES})
else()
  # pkg-config 没找到就直接链 system libuv
  target_link_libraries(chez-async-rt PRIVATE uv)
endif()

# 产物名 libchez-async-rt.so（去掉 CMake 默认可能的额外前缀行为）
set_target_properties(chez-async-rt PROPERTIES
  OUTPUT_NAME chez-async-rt)
