#include "cloop.h"
#include <cassert>
#include <cstdlib>
#include <exception>
#include <uv.h>
#ifdef __cplusplus

extern "C" {

CLoop *createEventLoop() {
  try {
    return new CLoop();
  } catch (std::bad_alloc &e) {
    return NULL;
  }
}

bool closeEventLoop(CLoop *pInstance) {
  assert(NULL != pInstance);
  if (pInstance->close()) {
    return false;
  }
  delete pInstance;
  return true;
}

int runEventLoop(CLoop *pInstance) {
  assert(NULL != pInstance);
  return pInstance->run();
}

void stopEventLoop(CLoop *pInstance) {
  assert(NULL != pInstance);
  pInstance->stop();
}
}
#endif
