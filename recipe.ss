#!chezscheme
;;; recipe.ss --- bake 构建描述
;;;
;;;   bake            # = bake build：编 native 运行时 + (chez-async) 库树
;;;   bake runtime    # 只编 C++ task 运行时 → native/runtime/native/<mt>/chez-async-rt.so
;;;   bake libs       # 只编 (chez-async) umbrella + import 闭包为 .so
;;;   bake test       # 跑全测试套件
;;;   bake -T         # 列任务
;;;   bake -c         # 清理声明的产物
;;;
;;; native 运行时（移植自 skiff src/runtime）是 Model A 纯 C ABI：不需要任何
;;; Chez 头，bake 用 cmake 后端编，产物落约定位置
;;; native/runtime/native/<machine-type>/chez-async-rt.so。

(define-lib-roots ".")                       ; 库搜索根 = 仓库根（umbrella chez-async.ss 在根）

;; ── native：C++ task 运行时（cmake 后端，Model A）──
(native-task 'runtime
  (dir "native/runtime")
  (build (cmake (targets "chez-async-rt")))
  (produces "chez-async-rt"))

;; ── libs：编 (chez-async) umbrella + 其 import 闭包为 .so ──
(library-task 'libs '(chez-async))

;; ── build（默认）：native + 库树 ──
(task 'build "编译 native 运行时 + (chez-async) 库树"
  '(runtime libs)
  (lambda () (values)))

;; ── test：跑全测试套件（解释执行）──
(task 'test "跑全测试套件（19+ 套件）"
  '(runtime)
  (lambda () (run "./run-tests.sh")))

(default-task 'build)
