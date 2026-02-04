#!/usr/bin/env scheme-script
;;; tests/test-fs.ss - File System 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level fs)
        (chez-async ffi fs))

;; 辅助函数（必须在测试之前定义）
(define (bytevector-truncate bv len)
  "截断 bytevector 到指定长度"
  (let ([result (make-bytevector len)])
    (bytevector-copy! bv 0 result 0 len)
    result))

(define (find-first pred lst)
  "查找满足谓词的第一个元素"
  (cond
    [(null? lst) #f]
    [(pred (car lst)) (car lst)]
    [else (find-first pred (cdr lst))]))

;; 测试目录
(define test-dir "/tmp/chez-async-fs-test")

;; 清理测试目录
(define (cleanup-test-dir)
  (when (file-exists? test-dir)
    (system (format "rm -rf ~a" test-dir))))

;; 初始化
(cleanup-test-dir)

(test-group "File System Tests"

  (test "fs-mkdir"
    (let* ([loop (uv-loop-init)]
           [result #f]
           [got-error #f])
      (uv-fs-mkdir loop test-dir
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! result r))))
      (uv-run loop 'default)
      (assert-false got-error "should not have error")
      (assert-true (file-exists? test-dir) "directory should exist")
      (uv-loop-close loop)))

  (test "fs-open-write-close"
    (let* ([loop (uv-loop-init)]
           [test-file (string-append test-dir "/test.txt")]
           [fd #f]
           [got-error #f])
      ;; 打开文件（创建）
      (uv-fs-open loop test-file
        (bitwise-ior O_WRONLY O_CREAT O_TRUNC)
        #o644
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! fd r))))
      (uv-run loop 'default)
      (assert-false got-error "open should not have error")
      (assert-true (and fd (> fd 0)) "should have valid fd")

      ;; 写入数据
      (let ([write-result #f])
        (uv-fs-write loop fd "Hello, World!\n"
          (lambda (r err)
            (if err
                (set! got-error err)
                (set! write-result r))))
        (uv-run loop 'default)
        (assert-false got-error "write should not have error")
        (assert-equal 14 write-result "should write 14 bytes"))

      ;; 关闭文件
      (uv-fs-close loop fd
        (lambda (r err)
          (when err (set! got-error err))))
      (uv-run loop 'default)
      (assert-false got-error "close should not have error")
      (assert-true (file-exists? test-file) "file should exist")
      (uv-loop-close loop)))

  (test "fs-open-read-close"
    (let* ([loop (uv-loop-init)]
           [test-file (string-append test-dir "/test.txt")]
           [fd #f]
           [got-error #f])
      ;; 打开文件（读取）
      (uv-fs-open loop test-file O_RDONLY 0
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! fd r))))
      (uv-run loop 'default)
      (assert-false got-error "open should not have error")
      (assert-true (and fd (> fd 0)) "should have valid fd")

      ;; 读取数据
      (let ([buffer (make-bytevector 100)]
            [read-result #f])
        (uv-fs-read loop fd buffer
          (lambda (r err)
            (if err
                (set! got-error err)
                (set! read-result r))))
        (uv-run loop 'default)
        (assert-false got-error "read should not have error")
        (assert-equal 14 read-result "should read 14 bytes")
        (assert-equal "Hello, World!\n"
                      (utf8->string (bytevector-truncate buffer read-result))
                      "content should match"))

      ;; 关闭文件
      (uv-fs-close loop fd
        (lambda (r err)
          (when err (set! got-error err))))
      (uv-run loop 'default)
      (assert-false got-error "close should not have error")
      (uv-loop-close loop)))

  (test "fs-stat"
    (let* ([loop (uv-loop-init)]
           [test-file (string-append test-dir "/test.txt")]
           [stat-result #f]
           [got-error #f])
      (uv-fs-stat loop test-file
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! stat-result r))))
      (uv-run loop 'default)
      (assert-false got-error "should not have error")
      (assert-true (stat-result? stat-result) "should be stat-result")
      (assert-equal 14 (stat-result-size stat-result) "size should be 14")
      (uv-loop-close loop)))

  (test "fs-rename"
    (let* ([loop (uv-loop-init)]
           [old-file (string-append test-dir "/test.txt")]
           [new-file (string-append test-dir "/renamed.txt")]
           [result #f]
           [got-error #f])
      (uv-fs-rename loop old-file new-file
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! result r))))
      (uv-run loop 'default)
      (assert-false got-error "should not have error")
      (assert-false (file-exists? old-file) "old file should not exist")
      (assert-true (file-exists? new-file) "new file should exist")
      (uv-loop-close loop)))

  (test "fs-scandir"
    (let* ([loop (uv-loop-init)]
           [dirents #f]
           [got-error #f])
      (uv-fs-scandir loop test-dir
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! dirents r))))
      (uv-run loop 'default)
      (assert-false got-error "should not have error")
      (assert-true (pair? dirents) "should have entries")
      (assert-true (find-first (lambda (d) (string=? "renamed.txt" (dirent-name d)))
                         dirents)
                   "should contain renamed.txt")
      (uv-loop-close loop)))

  (test "fs-copyfile"
    (let* ([loop (uv-loop-init)]
           [src-file (string-append test-dir "/renamed.txt")]
           [dest-file (string-append test-dir "/copied.txt")]
           [result #f]
           [got-error #f])
      (uv-fs-copyfile loop src-file dest-file
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! result r))))
      (uv-run loop 'default)
      (assert-false got-error "should not have error")
      (assert-true (file-exists? dest-file) "copied file should exist")
      (uv-loop-close loop)))

  (test "fs-unlink"
    (let* ([loop (uv-loop-init)]
           [test-file (string-append test-dir "/copied.txt")]
           [result #f]
           [got-error #f])
      (uv-fs-unlink loop test-file
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! result r))))
      (uv-run loop 'default)
      (assert-false got-error "should not have error")
      (assert-false (file-exists? test-file) "file should be deleted")
      (uv-loop-close loop)))

  (test "fs-sync-operations"
    (let* ([loop (uv-loop-init)]
           [test-file (string-append test-dir "/sync-test.txt")])
      ;; 同步写入
      (let ([fd (uv-fs-open-sync loop test-file
                  (bitwise-ior O_WRONLY O_CREAT O_TRUNC) #o644)])
        (assert-true (> fd 0) "should have valid fd")
        (let ([written (uv-fs-write-sync loop fd "Sync test\n")])
          (assert-equal 10 written "should write 10 bytes"))
        (uv-fs-close-sync loop fd))

      ;; 同步读取
      (let ([fd (uv-fs-open-sync loop test-file O_RDONLY 0)]
            [buffer (make-bytevector 20)])
        (let ([read (uv-fs-read-sync loop fd buffer)])
          (assert-equal 10 read "should read 10 bytes")
          (assert-equal "Sync test\n"
                        (utf8->string (bytevector-truncate buffer read))
                        "content should match"))
        (uv-fs-close-sync loop fd))

      ;; 同步 stat
      (let ([stat (uv-fs-stat-sync loop test-file)])
        (assert-true (stat-result? stat) "should be stat-result")
        (assert-equal 10 (stat-result-size stat) "size should be 10"))

      (uv-loop-close loop)))

  (test "fs-rmdir"
    (let* ([loop (uv-loop-init)]
           ;; 先删除目录中的文件
           [_ (begin
                (uv-fs-unlink-sync loop (string-append test-dir "/renamed.txt"))
                (uv-fs-unlink-sync loop (string-append test-dir "/sync-test.txt")))]
           [result #f]
           [got-error #f])
      (uv-fs-rmdir loop test-dir
        (lambda (r err)
          (if err
              (set! got-error err)
              (set! result r))))
      (uv-run loop 'default)
      (assert-false got-error "should not have error")
      (assert-false (file-exists? test-dir) "directory should be deleted")
      (uv-loop-close loop)))

) ; end test-group

;; 清理
(cleanup-test-dir)

(run-tests)
