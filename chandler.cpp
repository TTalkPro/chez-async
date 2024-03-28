#include "chandler.h"

void CHandler::onAllocBufferCallback(uv_handle_t *handle, size_t suggested_size,
                                 uv_buf_t *buf) {
  CHandler *pInstance = (CHandler *)handle->data;
  pInstance->onAllocBuffer(handle, suggested_size, buf);
}
