#include <uv.h>
#include "ctcp.h"
#ifdef __cplusplus
extern "C" {
  CTcp *createTcpInstance(uv_loop_t *pLoop) {
    CTcp *_pInstance = new CTcp(pLoop);
    return _pInstance;
  }

  bool tcpConnect(CTcp *pInstance, char *pAddr, int nPort) {
    return pInstance->doConnect(pAddr, nPort);
  }
}
#endif
