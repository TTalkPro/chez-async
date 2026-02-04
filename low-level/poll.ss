;;; low-level/poll.ss - Poll 低层封装
;;;
;;; 提供文件描述符轮询的高层封装
;;;
;;; Poll 用于监视任意文件描述符的可读/可写状态

(library (chez-async low-level poll)
  (export
    ;; Poll 创建
    uv-poll-init
    uv-poll-init-socket

    ;; Poll 控制
    uv-poll-start!
    uv-poll-stop!

    ;; 事件常量（从 ffi/types 重新导出）
    UV_READABLE
    UV_WRITABLE
    UV_DISCONNECT
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi poll)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal handle-utils))

  ;; ========================================
  ;; 全局 Poll 回调
  ;; ========================================

  (define-registered-callback get-poll-callback CALLBACK-POLL
    (lambda ()
      (make-poll-callback
        (lambda (wrapper status events)
          (let ([user-callback (handle-data wrapper)])
            (when user-callback
              (if (< status 0)
                  (user-callback wrapper (make-uv-error status (%ffi-uv-err-name status) 'poll) 0)
                  (user-callback wrapper #f events))))))))

  ;; ========================================
  ;; Poll 创建
  ;; ========================================

  (define (uv-poll-init loop fd)
    "创建 Poll 句柄
     loop: 事件循环
     fd: 要监视的文件描述符"
    (let* ([size (%ffi-uv-poll-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-poll-init
        (%ffi-uv-poll-init loop-ptr ptr fd)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'poll loop)))

  (define (uv-poll-init-socket loop socket)
    "从套接字创建 Poll 句柄（主要用于 Windows）
     loop: 事件循环
     socket: 套接字"
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
     poll: Poll 句柄
     events: UV_READABLE、UV_WRITABLE、UV_DISCONNECT 的组合
     callback: 回调函数 (lambda (poll error-or-#f events) ...)"
    (with-handle-check poll uv-poll-start!
      ;; 保存用户回调
      (handle-data-set! poll callback)
      (lock-object callback)
      ;; 开始轮询
      (with-uv-check uv-poll-start
        (%ffi-uv-poll-start (handle-ptr poll)
                            events
                            (get-poll-callback)))))

  (define (uv-poll-stop! poll)
    "停止轮询
     poll: Poll 句柄"
    (with-handle-check poll uv-poll-stop!
      (with-uv-check uv-poll-stop
        (%ffi-uv-poll-stop (handle-ptr poll)))
      ;; 清理回调
      (let ([callback (handle-data poll)])
        (when callback
          (unlock-object callback)
          (handle-data-set! poll #f)))))

) ; end library
