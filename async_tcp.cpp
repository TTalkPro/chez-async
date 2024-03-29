#include "ctcp.h"
#include <cstddef>
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
  size_t tcpRead(CTcp* pInstance,char* pData,int nLength){
    return pInstance->doRead(pData,nLength);
  }
  int tcpWrite(CTcp* pInstance,char* pData,int nLength){
    return pInstance->doWrite(pData,nLength);
  }
}
#endif
