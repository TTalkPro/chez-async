#include <uv.h>

#define STATUS_FUNC_ON_READ 0
#define STATUS_FUNC_ON_WRITE 1
#define STATUS_FUNC_ON_SEND 2 // 处理UDP发送成功消息
#define STATUS_FUNC_ON_CONNECTED 3
#define STATUS_FUNC_ON_ACCEPTED 4
#define STATUS_FUNC_ON_SHUTDOWN 5
#define STATUS_FUNC_ON_SIGNAL 6

#define SIMPLE_FUNC_ON_CLOSED 0
#define SIMPLE_FUNC_ON_TIMER 1
#define SIMPLE_FUNC_ON_PREPARE 2 // 每次事件循环前调用
#define SIMPLE_FUNC_ON_CHECK 3   // 每次事件循环后调用
// 如果存在一个活跃的idle handler，event loop会进行timeout为0的时间polling
#define SIMPLE_FUNC_ON_IDLE 4
// 异步任务调用，需要注意是async就是pipeline，是可以用uv_close进行close的
#define SIMPLE_FUNC_ON_ASYNC 5

#define CONTEXT_FUNC_ON_RECV 0     // 处理UDP收到数据了
#define CONTEXT_FUNC_ON_FS_EVENT 1 // 处理文件系统事件
class CLoop {
  typedef void (*SimpleCallback)(void *);
  typedef void (*StatusCallback)(void *, int);
  typedef void (*ContextCallback)(void *, void *, int);

public:
  CLoop();
  ~CLoop();

private:
  uv_loop_t *_pCtx;
  uv_prepare_t _sPrepare;
  uv_check_t _sCheck;
  uv_idle_t _sIdle;
  StatusCallback _aStatusFunc[6];
  SimpleCallback _aSimpleFunc[6];
  ContextCallback _aContextFunc[1];

public:
  inline uv_loop_t* theLoop() { return _pCtx; }
  bool close();
  int run();
  void stop();

public:
  inline void *registerStatusCallback(void *pFunc, int nFuncIdx) {
    void *_pOld = (void *)_aStatusFunc[nFuncIdx];
    _aStatusFunc[nFuncIdx] = (StatusCallback)pFunc;
    return _pOld;
  }
  inline void *registerSimpleCallback(void *pFunc, int nFuncIdx) {
    void *_pOld = (void *)_aSimpleFunc[nFuncIdx];
    _aSimpleFunc[nFuncIdx] = (SimpleCallback)pFunc;
    return _pOld;
  }

  inline void *registerContextCallback(void *pFunc, int nFuncIdx) {
    void *_pOld = (void *)_aContextFunc[nFuncIdx];
    _aContextFunc[nFuncIdx] = (ContextCallback)pFunc;
    return _pOld;
  }

public:
  void onStatusCallback(int nFuncIdx, void *pCtx, int status);
  void onContextCallback(int nFuncIdx, void *pCtx, void *pCallbacCtx,
                         int status);
  void onSimpleCallback(int nFuncIdx, void *pCtx);

  static void onStatusCallback(uv_loop_t *pLoop, int nFuncIdx, void *pCtx,
                               int status);

  static void onContextCallback(uv_loop_t *pLoop, int nFuncIdx, void *pCtx,
                                void *pCallbacCtx, int status);
  static void onSimpleCallback(uv_loop_t *pLoop, int nFuncIdx, void *pCtx);
};
