#include <cstdlib>
#include <uv.h>
#ifdef __cplusplus
extern "C" {
  uv_loop_t* createEventLoop(){
    uv_loop_t* _pInstance = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    if(NULL == _pInstance)
      return NULL;
    if(uv_loop_init(_pInstance)){
      free(_pInstance);
      return NULL;
    }
    return _pInstance;
  }
  bool closeEventLoop(uv_loop_t* pLoop){
    if(uv_loop_close(pLoop)){
      return false;
    }
    free(pLoop);
    return true;
  }

  void runEventLoop(uv_loop_t* pLoop){
    uv_run(pLoop,UV_RUN_DEFAULT);
  }

  void stopEventLoop(uv_loop_t* pLoop){
    uv_stop(pLoop);
  }
}
#endif
