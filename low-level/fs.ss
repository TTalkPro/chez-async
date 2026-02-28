;;; low-level/fs.ss - File System 低层封装
;;;
;;; 提供 libuv 文件系统操作的 Scheme 封装。
;;;
;;; 异步操作模式：
;;; 大部分简单操作（open, close, unlink, chmod 等）使用 with-uv-request 宏，
;;; 该宏统一处理请求分配、包装器创建、错误检查和清理。
;;;
;;; 特殊操作：
;;; - read/write 需要额外的缓冲区管理（C 内存分配/复制/释放），不使用宏
;;; - stat 系列使用 get-fs-stat-callback（需要解析 uv_stat_t 结构）
;;; - scandir 使用 get-fs-scandir-callback（需要遍历目录项）
;;; - readlink 使用 get-fs-readlink-callback（需要读取 C 字符串）
;;;
;;; 同步版本：通过 run-sync 辅助函数包装异步操作，运行事件循环直到完成

(library (chez-async low-level fs)
  (export
    ;; 文件操作
    uv-fs-open
    uv-fs-close
    uv-fs-read
    uv-fs-write
    uv-fs-unlink
    uv-fs-rename
    uv-fs-copyfile

    ;; 文件元数据
    uv-fs-stat
    uv-fs-fstat
    uv-fs-lstat

    ;; 目录操作
    uv-fs-mkdir
    uv-fs-rmdir
    uv-fs-scandir

    ;; 链接操作
    uv-fs-readlink
    uv-fs-symlink
    uv-fs-link

    ;; 权限和属性
    uv-fs-chmod
    uv-fs-fchmod
    uv-fs-chown
    uv-fs-fchown

    ;; 文件截断和同步
    uv-fs-ftruncate
    uv-fs-fsync
    uv-fs-fdatasync

    ;; 同步版本
    uv-fs-open-sync
    uv-fs-close-sync
    uv-fs-read-sync
    uv-fs-write-sync
    uv-fs-stat-sync
    uv-fs-mkdir-sync
    uv-fs-rmdir-sync
    uv-fs-unlink-sync
    uv-fs-rename-sync
    uv-fs-scandir-sync

    ;; stat 结果处理
    make-stat-result
    stat-result?
    stat-result-dev
    stat-result-mode
    stat-result-nlink
    stat-result-uid
    stat-result-gid
    stat-result-rdev
    stat-result-ino
    stat-result-size
    stat-result-blksize
    stat-result-blocks
    stat-result-atime
    stat-result-mtime
    stat-result-ctime
    stat-result-birthtime

    ;; dirent 结果
    make-dirent
    dirent?
    dirent-name
    dirent-type
    dirent-file?
    dirent-directory?
    dirent-link?
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi fs)
          (chez-async ffi requests)
          (chez-async ffi callbacks)
          (chez-async low-level request-base)
          (chez-async ffi core)
          (chez-async internal loop-registry)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (only (chez-async internal foreign) c-string->string))

  ;; ========================================
  ;; 全局回调（使用统一注册表管理）
  ;; ========================================
  ;;
  ;; 所有文件系统回调都注册到统一注册表，在首次使用时延迟创建
  ;; c-string->string 从 foreign-utils 模块导入，避免重复定义

  ;; 通用 FS 回调：处理大多数文件系统操作
  (define-registered-callback get-fs-callback CALLBACK-FS
    (lambda ()
      (foreign-callable
        (lambda (req-ptr)
          (guard (e [else (handle-callback-error e)])
            (let ([wrapper (request-ptr->wrapper req-ptr)])
              (when wrapper
                (let ([user-callback (uv-request-wrapper-scheme-callback wrapper)]
                      [result (%ffi-uv-fs-req-result req-ptr)])
                  (when user-callback
                    (if (< result 0)
                        (user-callback #f (make-uv-error result (%ffi-uv-err-name result) 'fs))
                        (user-callback result #f)))
                  ;; 清理请求
                  (%ffi-uv-fs-req-cleanup req-ptr)
                  (cleanup-request-wrapper! wrapper))))))
        (void*) void)))

  ;; stat 回调：处理文件状态查询
  (define-registered-callback get-fs-stat-callback CALLBACK-FS-STAT
    (lambda ()
      (foreign-callable
        (lambda (req-ptr)
          (guard (e [else (handle-callback-error e)])
            (let ([wrapper (request-ptr->wrapper req-ptr)])
              (when wrapper
                (let ([user-callback (uv-request-wrapper-scheme-callback wrapper)]
                      [result (%ffi-uv-fs-req-result req-ptr)])
                  (when user-callback
                    (if (< result 0)
                        (user-callback #f (make-uv-error result (%ffi-uv-err-name result) 'fs-stat))
                        (let ([statbuf (%ffi-uv-fs-req-statbuf req-ptr)])
                          (user-callback (statbuf->stat-result statbuf) #f)))))
                  ;; 清理请求
                  (%ffi-uv-fs-req-cleanup req-ptr)
                  (cleanup-request-wrapper! wrapper)))))
        (void*) void)))

  ;; scandir 回调：处理目录扫描
  (define-registered-callback get-fs-scandir-callback CALLBACK-FS-SCANDIR
    (lambda ()
      (foreign-callable
        (lambda (req-ptr)
          (guard (e [else (handle-callback-error e)])
            (let ([wrapper (request-ptr->wrapper req-ptr)])
              (when wrapper
                (let ([user-callback (uv-request-wrapper-scheme-callback wrapper)]
                      [result (%ffi-uv-fs-req-result req-ptr)])
                  (when user-callback
                    (if (< result 0)
                        (user-callback #f (make-uv-error result (%ffi-uv-err-name result) 'fs-scandir))
                        ;; 读取所有目录项
                        (user-callback (read-dirents req-ptr) #f))))
                  ;; 清理请求
                  (%ffi-uv-fs-req-cleanup req-ptr)
                  (cleanup-request-wrapper! wrapper)))))
        (void*) void)))

  ;; readlink 回调：处理符号链接读取
  (define-registered-callback get-fs-readlink-callback CALLBACK-FS-READLINK
    (lambda ()
      (foreign-callable
        (lambda (req-ptr)
          (guard (e [else (handle-callback-error e)])
            (let ([wrapper (request-ptr->wrapper req-ptr)])
              (when wrapper
                (let ([user-callback (uv-request-wrapper-scheme-callback wrapper)]
                      [result (%ffi-uv-fs-req-result req-ptr)])
                  (when user-callback
                    (if (< result 0)
                        (user-callback #f (make-uv-error result (%ffi-uv-err-name result) 'fs-readlink))
                        (let ([ptr (%ffi-uv-fs-req-ptr req-ptr)])
                          (user-callback (c-string->string ptr) #f)))))
                  ;; 清理请求
                  (%ffi-uv-fs-req-cleanup req-ptr)
                  (cleanup-request-wrapper! wrapper)))))
        (void*) void)))

  ;; ========================================
  ;; stat 结果记录类型
  ;; ========================================

  (define-record-type stat-result
    (fields
      (immutable dev)
      (immutable mode)
      (immutable nlink)
      (immutable uid)
      (immutable gid)
      (immutable rdev)
      (immutable ino)
      (immutable size)
      (immutable blksize)
      (immutable blocks)
      (immutable atime)
      (immutable mtime)
      (immutable ctime)
      (immutable birthtime))
    (protocol
      (lambda (new)
        (lambda (dev mode nlink uid gid rdev ino size blksize blocks
                 atime mtime ctime birthtime)
          (new dev mode nlink uid gid rdev ino size blksize blocks
               atime mtime ctime birthtime)))))

  (define (statbuf->stat-result statbuf)
    "将 uv_stat_t 转换为 stat-result"
    (make-stat-result
      (uv-stat-st-dev statbuf)
      (uv-stat-st-mode statbuf)
      (uv-stat-st-nlink statbuf)
      (uv-stat-st-uid statbuf)
      (uv-stat-st-gid statbuf)
      (uv-stat-st-rdev statbuf)
      (uv-stat-st-ino statbuf)
      (uv-stat-st-size statbuf)
      (uv-stat-st-blksize statbuf)
      (uv-stat-st-blocks statbuf)
      (uv-stat-st-atim statbuf)
      (uv-stat-st-mtim statbuf)
      (uv-stat-st-ctim statbuf)
      (uv-stat-st-birthtim statbuf)))

  ;; ========================================
  ;; dirent 记录类型
  ;; ========================================

  (define-record-type dirent
    (fields
      (immutable name)
      (immutable type))
    (protocol
      (lambda (new)
        (lambda (name type)
          (new name type)))))

  (define (dirent-file? d)
    "检查是否是普通文件"
    (= (dirent-type d) UV_DIRENT_FILE))

  (define (dirent-directory? d)
    "检查是否是目录"
    (= (dirent-type d) UV_DIRENT_DIR))

  (define (dirent-link? d)
    "检查是否是符号链接"
    (= (dirent-type d) UV_DIRENT_LINK))

  (define (read-dirents req-ptr)
    "从 scandir 请求中读取所有目录项"
    (let ([dirent-ptr (foreign-alloc 16)])  ; uv_dirent_t 大小
      (let loop ([entries '()])
        (let ([result (%ffi-uv-fs-scandir-next req-ptr dirent-ptr)])
          (if (< result 0)
              (begin
                (foreign-free dirent-ptr)
                (reverse entries))
              (let ([entry (make-dirent
                            (uv-dirent-name dirent-ptr)
                            (uv-dirent-type dirent-ptr))])
                (loop (cons entry entries))))))))

  ;; ========================================
  ;; 文件操作
  ;; ========================================

  (define (uv-fs-open loop path flags mode callback)
    "异步打开文件
     path: 文件路径
     flags: 打开标志（O_RDONLY, O_WRONLY, O_RDWR, O_CREAT 等）
     mode: 创建文件时的权限（如 #o644）
     callback: (lambda (fd error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-open cleanup-request-wrapper!)
      (%ffi-uv-fs-open (uv-loop-ptr loop) req-ptr path flags mode (get-fs-callback))))

  (define (uv-fs-close loop fd callback)
    "异步关闭文件
     fd: 文件描述符
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-close cleanup-request-wrapper!)
      (%ffi-uv-fs-close (uv-loop-ptr loop) req-ptr fd (get-fs-callback))))

  (define uv-fs-read
    (case-lambda
      [(loop fd buffer callback)
       (uv-fs-read loop fd buffer -1 callback)]
      [(loop fd buffer offset callback)
       "异步读取文件
        fd: 文件描述符
        buffer: bytevector（将读取到此缓冲区）
        offset: 文件偏移量（-1 表示当前位置）
        callback: (lambda (bytes-read error) ...)"
       (let* ([len (bytevector-length buffer)]
              [data-ptr (foreign-alloc len)]
              [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))]
              [req-size (%ffi-uv-fs-req-size)]
              [req-ptr (allocate-request req-size)])
         ;; 设置 uv_buf_t
         (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
           (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
           (ftype-set! uv-buf-t (len) buf-fptr len))
         ;; 创建包装器（保存缓冲区信息）
         (let ([req-wrapper (make-uv-request-wrapper
                              req-ptr 'fs
                              (lambda (result error)
                                ;; 复制数据到 bytevector
                                (when (and (not error) (> result 0))
                                  (do ([i 0 (+ i 1)])
                                      ((= i result))
                                    (bytevector-u8-set! buffer i
                                      (foreign-ref 'unsigned-8 data-ptr i))))
                                ;; 释放临时缓冲区
                                (foreign-free data-ptr)
                                (foreign-free buf-ptr)
                                ;; 调用用户回调
                                (callback result error))
                              #f)])
           (let ([result (%ffi-uv-fs-read
                           (uv-loop-ptr loop)
                           req-ptr
                           fd
                           buf-ptr
                           1  ; nbufs
                           offset
                           (get-fs-callback))])
             (when (< result 0)
               (foreign-free data-ptr)
               (foreign-free buf-ptr)
               (cleanup-request-wrapper! req-wrapper)
               (raise-uv-error result 'uv-fs-read)))))]))

  (define uv-fs-write
    (case-lambda
      [(loop fd data callback)
       (uv-fs-write loop fd data -1 callback)]
      [(loop fd data offset callback)
       "异步写入文件
        fd: 文件描述符
        data: bytevector 或 string
        offset: 文件偏移量（-1 表示当前位置）
        callback: (lambda (bytes-written error) ...)"
       (let* ([bv (if (string? data) (string->utf8 data) data)]
              [len (bytevector-length bv)]
              [data-ptr (foreign-alloc len)]
              [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))]
              [req-size (%ffi-uv-fs-req-size)]
              [req-ptr (allocate-request req-size)])
         ;; 复制数据到 C 内存
         (do ([i 0 (+ i 1)])
             ((= i len))
           (foreign-set! 'unsigned-8 data-ptr i (bytevector-u8-ref bv i)))
         ;; 设置 uv_buf_t
         (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
           (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
           (ftype-set! uv-buf-t (len) buf-fptr len))
         ;; 创建包装器
         (let ([req-wrapper (make-uv-request-wrapper
                              req-ptr 'fs
                              (lambda (result error)
                                ;; 释放缓冲区
                                (foreign-free data-ptr)
                                (foreign-free buf-ptr)
                                ;; 调用用户回调
                                (callback result error))
                              #f)])
           (let ([result (%ffi-uv-fs-write
                           (uv-loop-ptr loop)
                           req-ptr
                           fd
                           buf-ptr
                           1  ; nbufs
                           offset
                           (get-fs-callback))])
             (when (< result 0)
               (foreign-free data-ptr)
               (foreign-free buf-ptr)
               (cleanup-request-wrapper! req-wrapper)
               (raise-uv-error result 'uv-fs-write)))))]))

  (define (uv-fs-unlink loop path callback)
    "异步删除文件
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-unlink cleanup-request-wrapper!)
      (%ffi-uv-fs-unlink (uv-loop-ptr loop) req-ptr path (get-fs-callback))))

  (define (uv-fs-rename loop path new-path callback)
    "异步重命名/移动文件
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-rename cleanup-request-wrapper!)
      (%ffi-uv-fs-rename (uv-loop-ptr loop) req-ptr path new-path (get-fs-callback))))

  (define uv-fs-copyfile
    (case-lambda
      [(loop src dest callback)
       (uv-fs-copyfile loop src dest 0 callback)]
      [(loop src dest flags callback)
       "异步复制文件
        flags: UV_FS_COPYFILE_EXCL 等
        callback: (lambda (result error) ...)"
       (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-copyfile cleanup-request-wrapper!)
         (%ffi-uv-fs-copyfile (uv-loop-ptr loop) req-ptr src dest flags (get-fs-callback)))]))

  ;; ========================================
  ;; 文件元数据
  ;; ========================================

  (define (uv-fs-stat loop path callback)
    "异步获取文件状态
     callback: (lambda (stat-result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-stat cleanup-request-wrapper!)
      (%ffi-uv-fs-stat (uv-loop-ptr loop) req-ptr path (get-fs-stat-callback))))

  (define (uv-fs-fstat loop fd callback)
    "异步获取文件状态（通过文件描述符）
     callback: (lambda (stat-result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-fstat cleanup-request-wrapper!)
      (%ffi-uv-fs-fstat (uv-loop-ptr loop) req-ptr fd (get-fs-stat-callback))))

  (define (uv-fs-lstat loop path callback)
    "异步获取链接状态（不跟随符号链接）
     callback: (lambda (stat-result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-lstat cleanup-request-wrapper!)
      (%ffi-uv-fs-lstat (uv-loop-ptr loop) req-ptr path (get-fs-stat-callback))))

  ;; ========================================
  ;; 目录操作
  ;; ========================================

  (define uv-fs-mkdir
    (case-lambda
      [(loop path callback)
       (uv-fs-mkdir loop path #o755 callback)]
      [(loop path mode callback)
       "异步创建目录
        mode: 目录权限（默认 #o755）
        callback: (lambda (result error) ...)"
       (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-mkdir cleanup-request-wrapper!)
         (%ffi-uv-fs-mkdir (uv-loop-ptr loop) req-ptr path mode (get-fs-callback)))]))

  (define (uv-fs-rmdir loop path callback)
    "异步删除目录（必须为空）
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-rmdir cleanup-request-wrapper!)
      (%ffi-uv-fs-rmdir (uv-loop-ptr loop) req-ptr path (get-fs-callback))))

  (define (uv-fs-scandir loop path callback)
    "异步扫描目录
     callback: (lambda (dirents error) ...)
               dirents 是 dirent 记录列表"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-scandir cleanup-request-wrapper!)
      (%ffi-uv-fs-scandir (uv-loop-ptr loop) req-ptr path 0 (get-fs-scandir-callback))))

  ;; ========================================
  ;; 链接操作
  ;; ========================================

  (define (uv-fs-readlink loop path callback)
    "异步读取符号链接目标
     callback: (lambda (target error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-readlink cleanup-request-wrapper!)
      (%ffi-uv-fs-readlink (uv-loop-ptr loop) req-ptr path (get-fs-readlink-callback))))

  (define uv-fs-symlink
    (case-lambda
      [(loop path new-path callback)
       (uv-fs-symlink loop path new-path 0 callback)]
      [(loop path new-path flags callback)
       "异步创建符号链接
        path: 目标路径
        new-path: 链接路径
        flags: UV_FS_SYMLINK_DIR 等
        callback: (lambda (result error) ...)"
       (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-symlink cleanup-request-wrapper!)
         (%ffi-uv-fs-symlink (uv-loop-ptr loop) req-ptr path new-path flags (get-fs-callback)))]))

  (define (uv-fs-link loop path new-path callback)
    "异步创建硬链接
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-link cleanup-request-wrapper!)
      (%ffi-uv-fs-link (uv-loop-ptr loop) req-ptr path new-path (get-fs-callback))))

  ;; ========================================
  ;; 权限和属性
  ;; ========================================

  (define (uv-fs-chmod loop path mode callback)
    "异步修改文件权限
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-chmod cleanup-request-wrapper!)
      (%ffi-uv-fs-chmod (uv-loop-ptr loop) req-ptr path mode (get-fs-callback))))

  (define (uv-fs-fchmod loop fd mode callback)
    "异步修改文件权限（通过文件描述符）
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-fchmod cleanup-request-wrapper!)
      (%ffi-uv-fs-fchmod (uv-loop-ptr loop) req-ptr fd mode (get-fs-callback))))

  (define (uv-fs-chown loop path uid gid callback)
    "异步修改文件所有者
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-chown cleanup-request-wrapper!)
      (%ffi-uv-fs-chown (uv-loop-ptr loop) req-ptr path uid gid (get-fs-callback))))

  (define (uv-fs-fchown loop fd uid gid callback)
    "异步修改文件所有者（通过文件描述符）
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-fchown cleanup-request-wrapper!)
      (%ffi-uv-fs-fchown (uv-loop-ptr loop) req-ptr fd uid gid (get-fs-callback))))

  ;; ========================================
  ;; 文件截断和同步
  ;; ========================================

  (define (uv-fs-ftruncate loop fd length callback)
    "异步截断文件
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-ftruncate cleanup-request-wrapper!)
      (%ffi-uv-fs-ftruncate (uv-loop-ptr loop) req-ptr fd length (get-fs-callback))))

  (define (uv-fs-fsync loop fd callback)
    "异步同步文件到磁盘
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-fsync cleanup-request-wrapper!)
      (%ffi-uv-fs-fsync (uv-loop-ptr loop) req-ptr fd (get-fs-callback))))

  (define (uv-fs-fdatasync loop fd callback)
    "异步同步文件数据到磁盘（不含元数据）
     callback: (lambda (result error) ...)"
    (with-uv-request (req 'fs callback #f %ffi-uv-fs-req-size uv-fs-fdatasync cleanup-request-wrapper!)
      (%ffi-uv-fs-fdatasync (uv-loop-ptr loop) req-ptr fd (get-fs-callback))))

  ;; ========================================
  ;; 同步版本
  ;; ========================================

  (define (run-sync loop thunk)
    "运行异步操作并同步等待结果"
    (let ([result #f]
          [error #f]
          [done #f])
      (thunk (lambda (r e)
               (set! result r)
               (set! error e)
               (set! done #t)))
      (let loop-run ()
        (unless done
          (%ffi-uv-run (uv-loop-ptr loop) (uv-run-mode->int 'once))
          (loop-run)))
      (if error
          (raise error)
          result)))

  (define (uv-fs-open-sync loop path flags mode)
    "同步打开文件"
    (run-sync loop
      (lambda (cb) (uv-fs-open loop path flags mode cb))))

  (define (uv-fs-close-sync loop fd)
    "同步关闭文件"
    (run-sync loop
      (lambda (cb) (uv-fs-close loop fd cb))))

  (define uv-fs-read-sync
    (case-lambda
      [(loop fd buffer)
       (uv-fs-read-sync loop fd buffer -1)]
      [(loop fd buffer offset)
       "同步读取文件"
       (run-sync loop
         (lambda (cb) (uv-fs-read loop fd buffer offset cb)))]))

  (define uv-fs-write-sync
    (case-lambda
      [(loop fd data)
       (uv-fs-write-sync loop fd data -1)]
      [(loop fd data offset)
       "同步写入文件"
       (run-sync loop
         (lambda (cb) (uv-fs-write loop fd data offset cb)))]))

  (define (uv-fs-stat-sync loop path)
    "同步获取文件状态"
    (run-sync loop
      (lambda (cb) (uv-fs-stat loop path cb))))

  (define uv-fs-mkdir-sync
    (case-lambda
      [(loop path)
       (uv-fs-mkdir-sync loop path #o755)]
      [(loop path mode)
       "同步创建目录"
       (run-sync loop
         (lambda (cb) (uv-fs-mkdir loop path mode cb)))]))

  (define (uv-fs-rmdir-sync loop path)
    "同步删除目录"
    (run-sync loop
      (lambda (cb) (uv-fs-rmdir loop path cb))))

  (define (uv-fs-unlink-sync loop path)
    "同步删除文件"
    (run-sync loop
      (lambda (cb) (uv-fs-unlink loop path cb))))

  (define (uv-fs-rename-sync loop path new-path)
    "同步重命名/移动文件"
    (run-sync loop
      (lambda (cb) (uv-fs-rename loop path new-path cb))))

  (define (uv-fs-scandir-sync loop path)
    "同步扫描目录"
    (run-sync loop
      (lambda (cb) (uv-fs-scandir loop path cb))))

) ; end library
