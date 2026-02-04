;;; ffi/fs.ss - 文件系统 FFI 绑定
;;;
;;; 本模块提供 libuv 文件系统操作的 FFI 绑定。
;;;
;;; libuv 的文件系统 API 设计特点：
;;; - 所有操作都使用 uv_fs_t 请求结构
;;; - 支持同步（callback = NULL）和异步两种模式
;;; - 异步操作使用线程池执行，不阻塞事件循环
;;; - 操作完成后需要调用 uv_fs_req_cleanup 释放资源
;;;
;;; 主要功能分类：
;;; - 文件操作：open, close, read, write, unlink, rename, copyfile
;;; - 元数据：stat, fstat, lstat
;;; - 目录操作：mkdir, rmdir, scandir
;;; - 链接操作：readlink, symlink, link
;;; - 权限管理：chmod, chown
;;; - 同步操作：fsync, fdatasync, ftruncate

(library (chez-async ffi fs)
  (export
    ;; 文件基本操作
    %ffi-uv-fs-open       ; 打开文件
    %ffi-uv-fs-close      ; 关闭文件
    %ffi-uv-fs-read       ; 读取文件
    %ffi-uv-fs-write      ; 写入文件
    %ffi-uv-fs-unlink     ; 删除文件
    %ffi-uv-fs-rename     ; 重命名/移动文件
    %ffi-uv-fs-copyfile   ; 复制文件

    ;; 文件元数据
    %ffi-uv-fs-stat       ; 获取文件状态（跟随符号链接）
    %ffi-uv-fs-fstat      ; 获取文件状态（通过文件描述符）
    %ffi-uv-fs-lstat      ; 获取文件状态（不跟随符号链接）

    ;; 目录操作
    %ffi-uv-fs-mkdir      ; 创建目录
    %ffi-uv-fs-rmdir      ; 删除目录
    %ffi-uv-fs-scandir    ; 扫描目录
    %ffi-uv-fs-scandir-next ; 获取下一个目录项

    ;; 链接操作
    %ffi-uv-fs-readlink   ; 读取符号链接目标
    %ffi-uv-fs-symlink    ; 创建符号链接
    %ffi-uv-fs-link       ; 创建硬链接

    ;; 权限和属性
    %ffi-uv-fs-chmod      ; 修改文件权限
    %ffi-uv-fs-fchmod     ; 修改文件权限（通过 fd）
    %ffi-uv-fs-chown      ; 修改文件所有者
    %ffi-uv-fs-fchown     ; 修改文件所有者（通过 fd）

    ;; 文件截断和同步
    %ffi-uv-fs-ftruncate  ; 截断文件
    %ffi-uv-fs-fsync      ; 同步文件（包括元数据）
    %ffi-uv-fs-fdatasync  ; 同步文件（仅数据）

    ;; 请求结果访问
    %ffi-uv-fs-req-cleanup  ; 清理请求资源
    %ffi-uv-fs-req-result   ; 获取操作结果
    %ffi-uv-fs-req-ptr      ; 获取结果指针
    %ffi-uv-fs-req-path     ; 获取操作路径
    %ffi-uv-fs-req-statbuf  ; 获取 stat 结果

    ;; uv_stat_t 字段访问函数
    uv-stat-st-dev        ; 设备 ID
    uv-stat-st-mode       ; 文件模式（类型+权限）
    uv-stat-st-nlink      ; 硬链接数
    uv-stat-st-uid        ; 所有者用户 ID
    uv-stat-st-gid        ; 所有者组 ID
    uv-stat-st-rdev       ; 设备 ID（特殊文件）
    uv-stat-st-ino        ; inode 号
    uv-stat-st-size       ; 文件大小（字节）
    uv-stat-st-blksize    ; 最佳 I/O 块大小
    uv-stat-st-blocks     ; 已分配 512 字节块数
    uv-stat-st-flags      ; 文件标志（BSD 系统）
    uv-stat-st-gen        ; 文件代数（BSD 系统）
    uv-stat-st-atim       ; 最后访问时间
    uv-stat-st-mtim       ; 最后修改时间
    uv-stat-st-ctim       ; 最后状态变更时间
    uv-stat-st-birthtim   ; 创建时间

    ;; uv_dirent_t 字段访问
    uv-dirent-name        ; 目录项名称
    uv-dirent-type        ; 目录项类型

    ;; 文件打开标志（POSIX）
    O_RDONLY              ; 只读
    O_WRONLY              ; 只写
    O_RDWR                ; 读写
    O_CREAT               ; 不存在则创建
    O_EXCL                ; 与 O_CREAT 一起使用，存在则失败
    O_TRUNC               ; 截断为零长度
    O_APPEND              ; 追加模式
    O_SYNC                ; 同步写入（数据+元数据）
    O_DSYNC               ; 同步写入（仅数据）

    ;; 目录项类型常量
    UV_DIRENT_UNKNOWN     ; 未知类型
    UV_DIRENT_FILE        ; 普通文件
    UV_DIRENT_DIR         ; 目录
    UV_DIRENT_LINK        ; 符号链接
    UV_DIRENT_FIFO        ; FIFO/命名管道
    UV_DIRENT_SOCKET      ; Unix 域套接字
    UV_DIRENT_CHAR        ; 字符设备
    UV_DIRENT_BLOCK       ; 块设备

    ;; copyfile 标志
    UV_FS_COPYFILE_EXCL          ; 目标存在则失败
    UV_FS_COPYFILE_FICLONE       ; 尝试写时复制
    UV_FS_COPYFILE_FICLONE_FORCE ; 强制写时复制

    ;; symlink 标志（Windows）
    UV_FS_SYMLINK_DIR            ; 目录符号链接
    UV_FS_SYMLINK_JUNCTION       ; 目录连接点
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async ffi types)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 文件打开标志（POSIX）
  ;; ========================================

  (define O_RDONLY  #o0000)
  (define O_WRONLY  #o0001)
  (define O_RDWR    #o0002)
  (define O_CREAT   #o0100)
  (define O_EXCL    #o0200)
  (define O_TRUNC   #o1000)
  (define O_APPEND  #o2000)
  (define O_SYNC    #o4010000)  ; Linux: O_SYNC = __O_SYNC | O_DSYNC
  (define O_DSYNC   #o10000)

  ;; ========================================
  ;; dirent 类型
  ;; ========================================

  (define UV_DIRENT_UNKNOWN 0)
  (define UV_DIRENT_FILE    1)
  (define UV_DIRENT_DIR     2)
  (define UV_DIRENT_LINK    3)
  (define UV_DIRENT_FIFO    4)
  (define UV_DIRENT_SOCKET  5)
  (define UV_DIRENT_CHAR    6)
  (define UV_DIRENT_BLOCK   7)

  ;; ========================================
  ;; copyfile 标志
  ;; ========================================

  (define UV_FS_COPYFILE_EXCL 1)           ; 如果目标存在则失败
  (define UV_FS_COPYFILE_FICLONE 2)        ; 尝试创建写时复制链接
  (define UV_FS_COPYFILE_FICLONE_FORCE 4)  ; 必须创建写时复制链接

  ;; ========================================
  ;; symlink 标志
  ;; ========================================

  (define UV_FS_SYMLINK_DIR 1)       ; Windows: 目录符号链接
  (define UV_FS_SYMLINK_JUNCTION 2)  ; Windows: 目录连接点

  ;; ========================================
  ;; uv_stat_t 结构（基于 Linux x86_64）
  ;; ========================================

  ;; uv_stat_t 大小：128 字节（基于 libuv）
  (define uv-stat-size 128)

  ;; 字段偏移量
  (define st-dev-offset 0)        ; uint64_t
  (define st-mode-offset 8)       ; uint64_t
  (define st-nlink-offset 16)     ; uint64_t
  (define st-uid-offset 24)       ; uint64_t
  (define st-gid-offset 32)       ; uint64_t
  (define st-rdev-offset 40)      ; uint64_t
  (define st-ino-offset 48)       ; uint64_t
  (define st-size-offset 56)      ; uint64_t
  (define st-blksize-offset 64)   ; uint64_t
  (define st-blocks-offset 72)    ; uint64_t
  (define st-flags-offset 80)     ; uint64_t
  (define st-gen-offset 88)       ; uint64_t
  (define st-atim-offset 96)      ; uv_timespec_t (16 bytes)
  (define st-mtim-offset 112)     ; uv_timespec_t (16 bytes)
  (define st-ctim-offset 128)     ; uv_timespec_t (16 bytes)
  (define st-birthtim-offset 144) ; uv_timespec_t (16 bytes)

  ;; stat 字段访问函数
  (define (uv-stat-st-dev ptr)
    (foreign-ref 'unsigned-64 ptr st-dev-offset))

  (define (uv-stat-st-mode ptr)
    (foreign-ref 'unsigned-64 ptr st-mode-offset))

  (define (uv-stat-st-nlink ptr)
    (foreign-ref 'unsigned-64 ptr st-nlink-offset))

  (define (uv-stat-st-uid ptr)
    (foreign-ref 'unsigned-64 ptr st-uid-offset))

  (define (uv-stat-st-gid ptr)
    (foreign-ref 'unsigned-64 ptr st-gid-offset))

  (define (uv-stat-st-rdev ptr)
    (foreign-ref 'unsigned-64 ptr st-rdev-offset))

  (define (uv-stat-st-ino ptr)
    (foreign-ref 'unsigned-64 ptr st-ino-offset))

  (define (uv-stat-st-size ptr)
    (foreign-ref 'unsigned-64 ptr st-size-offset))

  (define (uv-stat-st-blksize ptr)
    (foreign-ref 'unsigned-64 ptr st-blksize-offset))

  (define (uv-stat-st-blocks ptr)
    (foreign-ref 'unsigned-64 ptr st-blocks-offset))

  (define (uv-stat-st-flags ptr)
    (foreign-ref 'unsigned-64 ptr st-flags-offset))

  (define (uv-stat-st-gen ptr)
    (foreign-ref 'unsigned-64 ptr st-gen-offset))

  ;; 时间戳访问（返回 (sec . nsec) 点对）
  (define (uv-stat-st-atim ptr)
    (cons (foreign-ref 'long ptr st-atim-offset)
          (foreign-ref 'long ptr (+ st-atim-offset 8))))

  (define (uv-stat-st-mtim ptr)
    (cons (foreign-ref 'long ptr st-mtim-offset)
          (foreign-ref 'long ptr (+ st-mtim-offset 8))))

  (define (uv-stat-st-ctim ptr)
    (cons (foreign-ref 'long ptr st-ctim-offset)
          (foreign-ref 'long ptr (+ st-ctim-offset 8))))

  (define (uv-stat-st-birthtim ptr)
    (cons (foreign-ref 'long ptr st-birthtim-offset)
          (foreign-ref 'long ptr (+ st-birthtim-offset 8))))

  ;; ========================================
  ;; uv_dirent_t 结构
  ;; ========================================

  ;; uv_dirent_t 结构（16 字节）
  (define dirent-name-offset 0)   ; const char*
  (define dirent-type-offset 8)   ; uv_dirent_type_t (int)

  (define (uv-dirent-name ptr)
    "获取目录项名称"
    (let ([name-ptr (foreign-ref 'void* ptr dirent-name-offset)])
      (if (= name-ptr 0)
          #f
          (c-string->string name-ptr))))

  (define (uv-dirent-type ptr)
    "获取目录项类型"
    (foreign-ref 'int ptr dirent-type-offset))

  ;; C 字符串转换辅助函数
  (define (c-string->string ptr)
    (if (= ptr 0)
        #f
        (let loop ([i 0] [chars '()])
          (let ([byte (foreign-ref 'unsigned-8 ptr i)])
            (if (= byte 0)
                (list->string (reverse chars))
                (loop (+ i 1) (cons (integer->char byte) chars)))))))

  ;; ========================================
  ;; 文件系统 FFI
  ;; ========================================

  ;; int uv_fs_open(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                int flags, int mode, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-open "uv_fs_open"
    (void* void* string int int void*) int)

  ;; int uv_fs_close(uv_loop_t* loop, uv_fs_t* req, uv_file file, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-close "uv_fs_close"
    (void* void* int void*) int)

  ;; int uv_fs_read(uv_loop_t* loop, uv_fs_t* req, uv_file file,
  ;;                const uv_buf_t bufs[], unsigned int nbufs,
  ;;                int64_t offset, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-read "uv_fs_read"
    (void* void* int void* unsigned-int long void*) int)

  ;; int uv_fs_write(uv_loop_t* loop, uv_fs_t* req, uv_file file,
  ;;                 const uv_buf_t bufs[], unsigned int nbufs,
  ;;                 int64_t offset, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-write "uv_fs_write"
    (void* void* int void* unsigned-int long void*) int)

  ;; int uv_fs_unlink(uv_loop_t* loop, uv_fs_t* req, const char* path, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-unlink "uv_fs_unlink"
    (void* void* string void*) int)

  ;; int uv_fs_rename(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                  const char* new_path, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-rename "uv_fs_rename"
    (void* void* string string void*) int)

  ;; int uv_fs_copyfile(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                    const char* new_path, int flags, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-copyfile "uv_fs_copyfile"
    (void* void* string string int void*) int)

  ;; ========================================
  ;; 文件元数据
  ;; ========================================

  ;; int uv_fs_stat(uv_loop_t* loop, uv_fs_t* req, const char* path, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-stat "uv_fs_stat"
    (void* void* string void*) int)

  ;; int uv_fs_fstat(uv_loop_t* loop, uv_fs_t* req, uv_file file, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-fstat "uv_fs_fstat"
    (void* void* int void*) int)

  ;; int uv_fs_lstat(uv_loop_t* loop, uv_fs_t* req, const char* path, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-lstat "uv_fs_lstat"
    (void* void* string void*) int)

  ;; ========================================
  ;; 目录操作
  ;; ========================================

  ;; int uv_fs_mkdir(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                 int mode, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-mkdir "uv_fs_mkdir"
    (void* void* string int void*) int)

  ;; int uv_fs_rmdir(uv_loop_t* loop, uv_fs_t* req, const char* path, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-rmdir "uv_fs_rmdir"
    (void* void* string void*) int)

  ;; int uv_fs_scandir(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                   int flags, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-scandir "uv_fs_scandir"
    (void* void* string int void*) int)

  ;; int uv_fs_scandir_next(uv_fs_t* req, uv_dirent_t* ent)
  (define-ffi %ffi-uv-fs-scandir-next "uv_fs_scandir_next"
    (void* void*) int)

  ;; ========================================
  ;; 链接操作
  ;; ========================================

  ;; int uv_fs_readlink(uv_loop_t* loop, uv_fs_t* req, const char* path, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-readlink "uv_fs_readlink"
    (void* void* string void*) int)

  ;; int uv_fs_symlink(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                   const char* new_path, int flags, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-symlink "uv_fs_symlink"
    (void* void* string string int void*) int)

  ;; int uv_fs_link(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                const char* new_path, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-link "uv_fs_link"
    (void* void* string string void*) int)

  ;; ========================================
  ;; 权限和属性
  ;; ========================================

  ;; int uv_fs_chmod(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                 int mode, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-chmod "uv_fs_chmod"
    (void* void* string int void*) int)

  ;; int uv_fs_fchmod(uv_loop_t* loop, uv_fs_t* req, uv_file file,
  ;;                  int mode, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-fchmod "uv_fs_fchmod"
    (void* void* int int void*) int)

  ;; int uv_fs_chown(uv_loop_t* loop, uv_fs_t* req, const char* path,
  ;;                 uv_uid_t uid, uv_gid_t gid, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-chown "uv_fs_chown"
    (void* void* string int int void*) int)

  ;; int uv_fs_fchown(uv_loop_t* loop, uv_fs_t* req, uv_file file,
  ;;                  uv_uid_t uid, uv_gid_t gid, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-fchown "uv_fs_fchown"
    (void* void* int int int void*) int)

  ;; ========================================
  ;; 文件截断和同步
  ;; ========================================

  ;; int uv_fs_ftruncate(uv_loop_t* loop, uv_fs_t* req, uv_file file,
  ;;                     int64_t offset, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-ftruncate "uv_fs_ftruncate"
    (void* void* int long void*) int)

  ;; int uv_fs_fsync(uv_loop_t* loop, uv_fs_t* req, uv_file file, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-fsync "uv_fs_fsync"
    (void* void* int void*) int)

  ;; int uv_fs_fdatasync(uv_loop_t* loop, uv_fs_t* req, uv_file file, uv_fs_cb cb)
  (define-ffi %ffi-uv-fs-fdatasync "uv_fs_fdatasync"
    (void* void* int void*) int)

  ;; ========================================
  ;; 请求访问函数
  ;; ========================================

  ;; void uv_fs_req_cleanup(uv_fs_t* req)
  (define-ffi %ffi-uv-fs-req-cleanup "uv_fs_req_cleanup"
    (void*) void)

  ;; ssize_t uv_fs_get_result(const uv_fs_t* req)
  (define-ffi %ffi-uv-fs-req-result "uv_fs_get_result"
    (void*) long)

  ;; void* uv_fs_get_ptr(const uv_fs_t* req)
  (define-ffi %ffi-uv-fs-req-ptr "uv_fs_get_ptr"
    (void*) void*)

  ;; const char* uv_fs_get_path(const uv_fs_t* req)
  (define-ffi %ffi-uv-fs-req-path "uv_fs_get_path"
    (void*) void*)

  ;; uv_stat_t* uv_fs_get_statbuf(uv_fs_t* req)
  (define-ffi %ffi-uv-fs-req-statbuf "uv_fs_get_statbuf"
    (void*) void*)

) ; end library
