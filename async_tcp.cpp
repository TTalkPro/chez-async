#include "ctcp.h"
#include <new>
#include <uv.h>
#ifdef __cplusplus
extern "C" {
CTcp *createTcpInstance(CLoop *pLoop) {
  try {
    return new CTcp(pLoop);
  } catch (std::bad_alloc &e) {
    return NULL;
  }
}

bool tcpConnect(CTcp *pInstance, char *pAddr, int nPort) {
  return pInstance->doConnect(pAddr, nPort);
}
}
#endif
