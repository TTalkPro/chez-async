;;; low-level/poll.ss - Poll 低层封装
;;;
;;; 提供文件描述符轮询的高层封装
;;;
;;; Poll 用于监视任意文件描述符的可读/可写状态，
;;; 适用于需要集成非 libuv 管理的文件描述符到事件循环的场景。
;;;
;;; 使用场景：
;;; - 监视非阻塞 socket（非 libuv 创建的）
;;; - 监视串口或其他设备文件
;;; - 集成第三方库的文件描述符
;;;
;;; 注意事项：
;;; - 不应用于常规文件（磁盘文件总是可读/可写）
;;; - 使用 epoll/kqueue/IOCP 实现，高效处理大量连接

(library (chez-async low-level poll)
  (export
    ;; Poll 创建
    uv-poll-init             ; 从文件描述符创建
    uv-poll-init-socket      ; 从套接字创建（Windows）

    ;; Poll 控制
    uv-poll-start!           ; 开始轮询
    uv-poll-stop!            ; 停止轮询

    ;; 事件常量（从 ffi/types 重新导出）
    UV_READABLE              ; 可读事件
    UV_WRITABLE              ; 可写事件
    UV_DISCONNECT            ; 断开连接事件
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi poll)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async internal loop-registry)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal handle-utils))

  ;; ========================================
  ;; 全局 Poll 回调
  ;; ========================================
  ;;
  ;; 使用统一回调注册表管理 Poll 回调。
  ;; 回调签名：void (*uv_poll_cb)(uv_poll_t* handle, int status, int events)
  ;;
  ;; 参数说明：
  ;; - status: 0 表示成功，< 0 表示错误
  ;; - events: 触发的事件掩码（UV_READABLE, UV_WRITABLE 等）

  (define-registered-callback get-poll-callback CALLBACK-POLL
    (lambda ()
      (make-poll-callback
        (lambda (wrapper status events)
          (let ([user-callback (handle-data wrapper)])
            (when user-callback
              (if (< status 0)
                  ;; 发生错误，传递错误对象
                  (user-callback wrapper
                                 (make-uv-error status (%ffi-uv-err-name status) 'poll)
                                 0)
                  ;; 成功，传递触发的事件
                  (user-callback wrapper #f events))))))))

  ;; ========================================
  ;; Poll 创建
  ;; ========================================

  (define (uv-poll-init loop fd)
    "从文件描述符创建 Poll 句柄

     参数：
       loop - 事件循环对象
       fd   - 要监视的文件描述符

     返回：
       新创建的 Poll 句柄包装器

     说明：
       Unix 上应使用此函数。
       文件描述符必须是有效的、支持 poll 的。"
    (let* ([size (%ffi-uv-poll-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-poll-init
        (%ffi-uv-poll-init loop-ptr ptr fd)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'poll loop)))

  (define (uv-poll-init-socket loop socket)
    "从套接字创建 Poll 句柄

     参数：
       loop   - 事件循环对象
       socket - 套接字句柄

     返回：
       新创建的 Poll 句柄包装器

     说明：
       Windows 上应使用此函数。
       socket 必须是有效的 Winsock 套接字。"
    (let* ([size (%ffi-uv-poll-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-poll-init-socket
        (%ffi-uv-poll-init-socket loop-ptr ptr socket)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'poll loop)))

  ;; ========================================
  ;; Poll 控制
  ;; ========================================

  (define (uv-poll-start! poll events callback)
    "开始轮询指定事件

     参数：
       poll     - Poll 句柄
       events   - 要监视的事件掩码（使用 bitwise-ior 组合）
                  UV_READABLE - 可读
                  UV_WRITABLE - 可写
                  UV_DISCONNECT - 断开连接
       callback - 回调函数 (lambda (poll error-or-#f events) ...)

     说明：
       当指定事件发生时调用回调。
       error 参数：#f 表示成功，否则为错误对象。
       events 参数：触发的事件掩码（可能与请求的不同）。"
    (with-handle-check poll uv-poll-start!
      ;; 释放旧回调
      (let ([old-callback (handle-data poll)])
        (when old-callback
          (unlock-object old-callback)))
      ;; 保存用户回调
      (handle-data-set! poll callback)
      (lock-object callback)
      ;; 开始轮询
      (with-uv-check uv-poll-start
        (%ffi-uv-poll-start (handle-ptr poll)
                            events
                            (get-poll-callback)))))

  (define-handle-stop! uv-poll-stop! %ffi-uv-poll-stop
    handle-ptr handle-data handle-data-set! handle-closed?)

) ; end library
