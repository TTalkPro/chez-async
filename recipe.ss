#!chezscheme
;;; recipe.ss --- bake 构建/安装描述
;;;
;;;   bake              # = bake build：编 native 运行时 + (chez-async) 库树
;;;   bake runtime      # 只编 C++ task 运行时 → native/<mt>/chez-async-rt.so
;;;   bake libs         # 只编 (chez-async) umbrella + import 闭包为 .so
;;;   bake test         # 跑全测试套件
;;;   bake install      # 装 (chez-async) 库树 + native/<mt>/*.so → ~/.local/share/chez/lib
;;;   bake uninstall    # 据安装清单干净卸载
;;;   bake -T           # 列任务    ·    bake -c   # 清理声明产物
;;;
;;; native 运行时（移植自 skiff src/runtime）是 Model A 纯 C ABI：不需要任何
;;; Chez 头。native-task 用 (dir ".")（项目自有 native 的惯用法），cmake 后端产物
;;; 落**约定位置 native/<machine-type>/chez-async-rt.so**——正是 install-task
;;; 随库树一起装到 Chez lib dir 的 native 子树的位置（designs/20+21）。

(define-lib-roots ".")                       ; 库搜索根 = 仓库根（umbrella chez-async.ss 在根）

;; ── native：C++ task 运行时（cmake 后端，Model A，dir "." → 落 native/<mt>/）──
(native-task 'runtime
  (dir ".")
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

;; ── install / uninstall：把 (chez-async) 库树 + native/<mt>/*.so 装进 Chez lib dir ──
;;   → (import (chez-async)) 全局可解析；native .so 随装到 <prefix>/native/<mt>/
;;     供统一加载（designs/20 §统一加载）。install 依赖 runtime（先编出 native）。
(install-task 'install
  (lib chez-async)
  (from ".")
  (target user))
(uninstall-task 'uninstall
  (lib chez-async)
  (target user))

(install-task 'install-global
  (lib chez-async)
  (from ".")
  (target global))
(uninstall-task 'uninstall-global
  (lib chez-async)
  (target global))

(default-task 'build)
