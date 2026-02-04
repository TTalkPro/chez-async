;;; ffi/stream.ss - 流（Stream）FFI 绑定
;;;
;;; 本模块提供 libuv 流句柄（uv_stream_t）的 FFI 绑定。
;;;
;;; 流是 libuv 中处理双向数据通道的抽象基类。
;;; 以下句柄类型继承自流：
;;; - TCP 套接字（uv_tcp_t）
;;; - 命名管道（uv_pipe_t）
;;; - TTY 终端（uv_tty_t）
;;;
;;; 流的核心操作：
;;; - 读取：使用回调异步接收数据
;;; - 写入：可以同步尝试或异步完成
;;; - 监听/接受：用于服务器
;;; - 关闭：优雅关闭（shutdown）或立即关闭

(library (chez-async ffi stream)
  (export
    ;; 读取操作
    %ffi-uv-read-start    ; 开始异步读取
    %ffi-uv-read-stop     ; 停止读取

    ;; 写入操作
    %ffi-uv-write         ; 异步写入
    %ffi-uv-write2        ; 异步写入并传递句柄
    %ffi-uv-try-write     ; 同步尝试写入
    %ffi-uv-shutdown      ; 优雅关闭写端

    ;; 服务器操作
    %ffi-uv-listen        ; 监听连接
    %ffi-uv-accept        ; 接受连接

    ;; 状态查询
    %ffi-uv-is-readable   ; 检查是否可读
    %ffi-uv-is-writable   ; 检查是否可写
    %ffi-uv-stream-get-write-queue-size ; 获取写队列大小
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; Stream 读取操作
  ;; ========================================

  ;; int uv_read_start(uv_stream_t* stream, uv_alloc_cb alloc_cb, uv_read_cb read_cb)
  ;; 开始从 stream 读取数据
  ;; alloc_cb: 分配缓冲区的回调 (handle, suggested_size, buf) -> void
  ;; read_cb: 读取完成的回调 (stream, nread, buf) -> void
  (define-ffi %ffi-uv-read-start "uv_read_start" (void* void* void*) int)

  ;; int uv_read_stop(uv_stream_t* stream)
  ;; 停止从 stream 读取数据
  (define-ffi %ffi-uv-read-stop "uv_read_stop" (void*) int)

  ;; ========================================
  ;; Stream 写入操作
  ;; ========================================

  ;; int uv_write(uv_write_t* req, uv_stream_t* handle, const uv_buf_t bufs[],
  ;;              unsigned-int nbufs, uv_write_cb cb)
  ;; 写入数据到 stream
  (define-ffi %ffi-uv-write "uv_write" (void* void* void* unsigned-int void*) int)

  ;; int uv_write2(uv_write_t* req, uv_stream_t* handle, const uv_buf_t bufs[],
  ;;               unsigned-int nbufs, uv_stream_t* send_handle, uv_write_cb cb)
  ;; 写入数据并传递句柄（用于 IPC）
  (define-ffi %ffi-uv-write2 "uv_write2" (void* void* void* unsigned-int void* void*) int)

  ;; int uv_try_write(uv_stream_t* handle, const uv_buf_t bufs[], unsigned-int nbufs)
  ;; 尝试同步写入（非阻塞）
  (define-ffi %ffi-uv-try-write "uv_try_write" (void* void* unsigned-int) int)

  ;; ========================================
  ;; Stream 关闭操作
  ;; ========================================

  ;; int uv_shutdown(uv_shutdown_t* req, uv_stream_t* handle, uv_shutdown_cb cb)
  ;; 关闭 stream 的写端（half-close）
  (define-ffi %ffi-uv-shutdown "uv_shutdown" (void* void* void*) int)

  ;; ========================================
  ;; Stream 服务器操作
  ;; ========================================

  ;; int uv_listen(uv_stream_t* stream, int backlog, uv_connection_cb cb)
  ;; 监听传入连接
  (define-ffi %ffi-uv-listen "uv_listen" (void* int void*) int)

  ;; int uv_accept(uv_stream_t* server, uv_stream_t* client)
  ;; 接受传入的连接
  (define-ffi %ffi-uv-accept "uv_accept" (void* void*) int)

  ;; ========================================
  ;; Stream 状态查询
  ;; ========================================

  ;; int uv_is_readable(const uv_stream_t* handle)
  ;; 检查 stream 是否可读
  (define-ffi %ffi-uv-is-readable "uv_is_readable" (void*) int)

  ;; int uv_is_writable(const uv_stream_t* handle)
  ;; 检查 stream 是否可写
  (define-ffi %ffi-uv-is-writable "uv_is_writable" (void*) int)

  ;; size_t uv_stream_get_write_queue_size(const uv_stream_t* stream)
  ;; 获取写队列中待写入的字节数
  (define-ffi %ffi-uv-stream-get-write-queue-size "uv_stream_get_write_queue_size" (void*) size_t)

) ; end library
