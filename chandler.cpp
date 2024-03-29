#include "chandler.h"

CHandler::CHandler(CLoop *pLoop, int nType)
  : _pLoop(pLoop), _nType(nType), _bInCallback(false),_bStarted(false){}
CHandler::CHandler(CLoop *pLoop) : CHandler(pLoop, HANDLER_TYPE_UNKNOWN) {}
CHandler::CHandler() : CHandler(NULL, HANDLER_TYPE_UNKNOWN) {}
void CHandler::onAllocBufferCallback(uv_handle_t *handle, size_t suggested_size,
                                 uv_buf_t *buf) {
  CHandler *pInstance = (CHandler *)handle->data;
  pInstance->onAllocBuffer(handle, suggested_size, buf);
}
