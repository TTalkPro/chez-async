;;; ffi/core.ss - 核心 FFI 绑定（事件循环和版本信息）
;;;
;;; 本模块提供 libuv 核心功能的 FFI 绑定：
;;; - 事件循环管理
;;; - 版本信息查询
;;;
;;; 这是所有其他 FFI 模块的基础，导入此模块即可确保 libuv 库已加载。

(library (chez-async ffi core)
  (export
    ;; 事件循环操作
    %ffi-uv-loop-init      ; 初始化事件循环
    %ffi-uv-loop-close     ; 关闭事件循环
    %ffi-uv-run            ; 运行事件循环
    %ffi-uv-stop           ; 停止事件循环
    %ffi-uv-loop-alive     ; 检查循环是否有活动句柄
    %ffi-uv-default-loop   ; 获取默认事件循环

    ;; 版本信息
    %ffi-uv-version        ; 获取版本号
    %ffi-uv-version-string ; 获取版本字符串

    ;; 事件循环大小（用于内存分配）
    %ffi-uv-loop-size
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async ffi types)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 事件循环 API
  ;; ========================================
  ;;
  ;; libuv 的事件循环是其核心组件，负责：
  ;; - 轮询 I/O 事件
  ;; - 执行定时器回调
  ;; - 处理异步操作完成通知

  ;; int uv_loop_init(uv_loop_t* loop)
  ;; 初始化事件循环结构
  ;; 返回值：0 表示成功，负数表示错误
  (define-ffi %ffi-uv-loop-init "uv_loop_init" (void*) int)

  ;; int uv_loop_close(uv_loop_t* loop)
  ;; 关闭事件循环，释放资源
  ;; 注意：必须在所有句柄关闭后才能调用
  (define-ffi %ffi-uv-loop-close "uv_loop_close" (void*) int)

  ;; int uv_run(uv_loop_t* loop, uv_run_mode mode)
  ;; 运行事件循环
  ;; mode 参数：
  ;;   UV_RUN_DEFAULT (0) - 运行直到没有活动句柄
  ;;   UV_RUN_ONCE (1)    - 处理一个事件后返回
  ;;   UV_RUN_NOWAIT (2)  - 非阻塞检查
  (define-ffi %ffi-uv-run "uv_run" (void* int) int)

  ;; void uv_stop(uv_loop_t* loop)
  ;; 停止事件循环
  ;; 下次 uv_run 返回时会退出
  (define-ffi %ffi-uv-stop "uv_stop" (void*) void)

  ;; int uv_loop_alive(const uv_loop_t* loop)
  ;; 检查事件循环是否有活动句柄或请求
  ;; 返回值：非零表示有活动，零表示空闲
  (define-ffi %ffi-uv-loop-alive "uv_loop_alive" (void*) int)

  ;; uv_loop_t* uv_default_loop(void)
  ;; 获取默认的事件循环（全局单例）
  ;; 注意：多线程程序中应避免使用
  (define-ffi %ffi-uv-default-loop "uv_default_loop" () void*)

  ;; ========================================
  ;; 版本信息 API
  ;; ========================================

  ;; unsigned int uv_version(void)
  ;; 获取 libuv 版本号（编码为整数）
  ;; 格式：(major << 16) | (minor << 8) | patch
  (define-ffi %ffi-uv-version "uv_version" () unsigned)

  ;; const char* uv_version_string(void)
  ;; 获取 libuv 版本字符串
  ;; 例如："1.50.0"
  (define-ffi %ffi-uv-version-string "uv_version_string" () string)

  ;; ========================================
  ;; 辅助函数
  ;; ========================================

  ;; size_t uv_loop_size(void)
  ;; 获取 uv_loop_t 结构的大小（字节）
  ;; 用于动态分配内存
  (define-ffi %ffi-uv-loop-size "uv_loop_size" () size_t)

) ; end library
