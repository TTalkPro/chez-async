cmake_minimum_required(VERSION 3.20)

project(chez-async-runtime
  DESCRIPTION "chez-async 的 Task-based I/O 运行时（移植自 skiff src/runtime @ 93e0fd6）"
  LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# system libuv（Model A：纯 C ABI，不需要任何 Chez 头）
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(LIBUV libuv)
endif()

# vendored 自 skiff src/runtime @ 93e0fd6（纯 C++/libuv，零 Chez 依赖）。
# task.hpp/net.hpp/runtime.hpp 是头文件；编译单元 = runtime.cpp + rt_ffi.cpp。
add_library(chez-async-rt SHARED
  runtime.cpp
  rt_ffi.cpp)

target_include_directories(chez-async-rt PRIVATE ${LIBUV_INCLUDE_DIRS})
if(LIBUV_LIBRARIES)
  target_link_libraries(chez-async-rt PRIVATE ${LIBUV_LIBRARIES})
else()
  target_link_libraries(chez-async-rt PRIVATE uv)
endif()

# bake native-task 契约：产物名 = <soname>.<ext> = chez-async-rt.so（无 lib 前缀），
# 且 `cmake --install` 把它落到 CMAKE_INSTALL_PREFIX（bake 传入的 landing 目录
# <pkg>/native/<machine-type>/）。
set_target_properties(chez-async-rt PROPERTIES
  PREFIX ""
  OUTPUT_NAME chez-async-rt)

install(TARGETS chez-async-rt LIBRARY DESTINATION .)
