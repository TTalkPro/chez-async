#!/usr/bin/env scheme-script
;;; examples/fs-demo.ss - 文件系统操作示例
;;;
;;; 这个示例展示了如何使用 chez-async 进行异步文件操作。

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level fs)
        (chez-async ffi fs))

;; ========================================
;; 示例 1: 基本文件读写
;; ========================================

(define (example-basic-io)
  (printf "~n=== Example 1: Basic File I/O ===~n")
  (let ([loop (uv-loop-init)]
        [test-file "/tmp/chez-async-demo.txt"])

    ;; 写入文件
    (printf "Writing to file...~n")
    (uv-fs-open loop test-file
      (bitwise-ior O_WRONLY O_CREAT O_TRUNC)
      #o644
      (lambda (fd err)
        (if err
            (printf "Error opening file: ~a~n" err)
            (begin
              (printf "Opened file, fd=~a~n" fd)
              (uv-fs-write loop fd "Hello from chez-async!\nThis is async file I/O.\n"
                (lambda (written err)
                  (if err
                      (printf "Error writing: ~a~n" err)
                      (printf "Wrote ~a bytes~n" written))
                  (uv-fs-close loop fd
                    (lambda (r err)
                      (if err
                          (printf "Error closing: ~a~n" err)
                          (printf "File closed~n"))))))))))

    (uv-run loop 'default)

    ;; 读取文件
    (printf "~nReading from file...~n")
    (uv-fs-open loop test-file O_RDONLY 0
      (lambda (fd err)
        (if err
            (printf "Error opening file: ~a~n" err)
            (let ([buffer (make-bytevector 100)])
              (uv-fs-read loop fd buffer
                (lambda (read-count err)
                  (if err
                      (printf "Error reading: ~a~n" err)
                      (begin
                        (printf "Read ~a bytes:~n" read-count)
                        (printf "~a" (utf8->string (bytevector-truncate buffer read-count)))))
                  (uv-fs-close loop fd
                    (lambda (r err) #f))))))))

    (uv-run loop 'default)

    ;; 删除文件
    (uv-fs-unlink loop test-file
      (lambda (r err)
        (if err
            (printf "Error deleting: ~a~n" err)
            (printf "File deleted~n"))))

    (uv-run loop 'default)
    (uv-loop-close loop)))

;; ========================================
;; 示例 2: 文件状态
;; ========================================

(define (example-file-stat)
  (printf "~n=== Example 2: File Status ===~n")
  (let ([loop (uv-loop-init)])
    (uv-fs-stat loop "/etc/passwd"
      (lambda (stat err)
        (if err
            (printf "Error: ~a~n" err)
            (begin
              (printf "File: /etc/passwd~n")
              (printf "  Size: ~a bytes~n" (stat-result-size stat))
              (printf "  Mode: ~o~n" (bitwise-and (stat-result-mode stat) #o777))
              (printf "  UID: ~a~n" (stat-result-uid stat))
              (printf "  GID: ~a~n" (stat-result-gid stat))
              (let ([mtime (stat-result-mtime stat)])
                (printf "  Modified: ~a seconds since epoch~n" (car mtime)))))))

    (uv-run loop 'default)
    (uv-loop-close loop)))

;; ========================================
;; 示例 3: 目录操作
;; ========================================

(define (example-directory-ops)
  (printf "~n=== Example 3: Directory Operations ===~n")
  (let ([loop (uv-loop-init)]
        [test-dir "/tmp/chez-async-dir-demo"])

    ;; 创建目录
    (printf "Creating directory...~n")
    (uv-fs-mkdir loop test-dir #o755
      (lambda (r err)
        (if err
            (printf "Error creating directory: ~a~n" err)
            (printf "Directory created: ~a~n" test-dir))))

    (uv-run loop 'default)

    ;; 创建一些文件
    (printf "Creating test files...~n")
    (for-each
      (lambda (name)
        (let ([path (string-append test-dir "/" name)])
          (uv-fs-open loop path
            (bitwise-ior O_WRONLY O_CREAT)
            #o644
            (lambda (fd err)
              (when (not err)
                (uv-fs-close loop fd (lambda (r e) #f)))))))
      '("file1.txt" "file2.txt" "file3.txt"))

    (uv-run loop 'default)

    ;; 扫描目录
    (printf "~nScanning directory...~n")
    (uv-fs-scandir loop test-dir
      (lambda (entries err)
        (if err
            (printf "Error scanning: ~a~n" err)
            (begin
              (printf "Directory contents:~n")
              (for-each
                (lambda (entry)
                  (printf "  ~a (~a)~n"
                          (dirent-name entry)
                          (dirent-type->string (dirent-type entry))))
                entries)))))

    (uv-run loop 'default)

    ;; 清理
    (printf "~nCleaning up...~n")
    (for-each
      (lambda (name)
        (uv-fs-unlink loop (string-append test-dir "/" name)
          (lambda (r e) #f)))
      '("file1.txt" "file2.txt" "file3.txt"))

    (uv-run loop 'default)

    (uv-fs-rmdir loop test-dir
      (lambda (r err)
        (if err
            (printf "Error removing directory: ~a~n" err)
            (printf "Directory removed~n"))))

    (uv-run loop 'default)
    (uv-loop-close loop)))

;; ========================================
;; 示例 4: 同步文件操作
;; ========================================

(define (example-sync-ops)
  (printf "~n=== Example 4: Synchronous Operations ===~n")
  (let ([loop (uv-loop-init)]
        [test-file "/tmp/chez-async-sync-demo.txt"])

    ;; 同步写入
    (printf "Synchronous write...~n")
    (let ([fd (uv-fs-open-sync loop test-file
                (bitwise-ior O_WRONLY O_CREAT O_TRUNC) #o644)])
      (let ([written (uv-fs-write-sync loop fd "Sync I/O demo\n")])
        (printf "Wrote ~a bytes~n" written))
      (uv-fs-close-sync loop fd))

    ;; 同步读取
    (printf "Synchronous read...~n")
    (let ([fd (uv-fs-open-sync loop test-file O_RDONLY 0)]
          [buffer (make-bytevector 50)])
      (let ([read (uv-fs-read-sync loop fd buffer)])
        (printf "Read ~a bytes: ~a" read
                (utf8->string (bytevector-truncate buffer read))))
      (uv-fs-close-sync loop fd))

    ;; 同步 stat
    (printf "Synchronous stat...~n")
    (let ([stat (uv-fs-stat-sync loop test-file)])
      (printf "File size: ~a bytes~n" (stat-result-size stat)))

    ;; 清理
    (uv-fs-unlink-sync loop test-file)
    (printf "File deleted~n")

    (uv-loop-close loop)))

;; ========================================
;; 示例 5: 文件复制
;; ========================================

(define (example-file-copy)
  (printf "~n=== Example 5: File Copy ===~n")
  (let ([loop (uv-loop-init)]
        [src-file "/tmp/chez-async-src.txt"]
        [dest-file "/tmp/chez-async-dest.txt"])

    ;; 创建源文件
    (let ([fd (uv-fs-open-sync loop src-file
                (bitwise-ior O_WRONLY O_CREAT O_TRUNC) #o644)])
      (uv-fs-write-sync loop fd "This is the source file content.\n")
      (uv-fs-close-sync loop fd))

    ;; 复制文件
    (printf "Copying file...~n")
    (uv-fs-copyfile loop src-file dest-file
      (lambda (r err)
        (if err
            (printf "Error copying: ~a~n" err)
            (printf "File copied successfully~n"))))

    (uv-run loop 'default)

    ;; 验证
    (let ([stat (uv-fs-stat-sync loop dest-file)])
      (printf "Destination file size: ~a bytes~n" (stat-result-size stat)))

    ;; 清理
    (uv-fs-unlink-sync loop src-file)
    (uv-fs-unlink-sync loop dest-file)
    (printf "Cleanup completed~n")

    (uv-loop-close loop)))

;; ========================================
;; 辅助函数
;; ========================================

(define (bytevector-truncate bv len)
  "截断 bytevector 到指定长度"
  (let ([result (make-bytevector len)])
    (bytevector-copy! bv 0 result 0 len)
    result))

(define (dirent-type->string type)
  "将目录项类型转换为字符串"
  (cond
    [(= type UV_DIRENT_FILE) "file"]
    [(= type UV_DIRENT_DIR) "directory"]
    [(= type UV_DIRENT_LINK) "symlink"]
    [(= type UV_DIRENT_FIFO) "fifo"]
    [(= type UV_DIRENT_SOCKET) "socket"]
    [(= type UV_DIRENT_CHAR) "char device"]
    [(= type UV_DIRENT_BLOCK) "block device"]
    [else "unknown"]))

;; ========================================
;; 主程序
;; ========================================

(define (main)
  (printf "=== chez-async: File System Demo ===~n")
  (printf "libuv version: ~a~n" (uv-version-string))

  (example-basic-io)
  (example-file-stat)
  (example-directory-ops)
  (example-sync-ops)
  (example-file-copy)

  (printf "~n=== All file system examples completed! ===~n"))

;; 运行
(main)
