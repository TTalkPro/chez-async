#include "cloop.h"
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <new>
#include <uv.h>

CLoop::CLoop() {
  std::bad_alloc exception;
  uv_loop_t *_pCtx = (uv_loop_t *)malloc(sizeof(uv_loop_t));
  if (NULL == _pCtx) {
    throw exception;
  }
  uv_loop_set_data(_pCtx, this);
  memset(_aContextFunc, 0, sizeof(_aContextFunc));
  memset(_aStatusFunc, 0, sizeof(_aStatusFunc));
  memset(_aSimpleFunc, 0, sizeof(_aSimpleFunc));
}

CLoop::~CLoop() {
  if (NULL != _pCtx) {
    free(_pCtx);
  }
  _pCtx = NULL;
}

void CLoop::onStatusCallback(int nFuncIdx, void *pCtx, int status) {
  StatusCallback _callback = _aStatusFunc[nFuncIdx];
  if (NULL != _callback) {
    _callback(pCtx, status);
  }
}
void CLoop::onSimpleCallback(int nFuncIdx, void *pCtx) {
  SimpleCallback _callback = _aSimpleFunc[nFuncIdx];
  if (NULL != _callback) {
    _callback(pCtx);
  }
}
void CLoop::onContextCallback(int nFuncIdx, void *pCtx, void *pCallbacCtx,
                              int status) {
  ContextCallback _callback = _aContextFunc[nFuncIdx];
  if (NULL != _callback) {
    _callback(pCtx, pCallbacCtx, status);
  }
}

void CLoop::onStatusCallback(uv_loop_t *pLoop, int nFuncIdx, void *pCtx,
                             int status) {
  CLoop *_pInstance = (CLoop *)uv_loop_get_data(pLoop);
  assert(NULL != _pInstance);
  _pInstance->onStatusCallback(nFuncIdx, pCtx, status);
}

void CLoop::onSimpleCallback(uv_loop_t *pLoop, int nFuncIdx, void *pCtx) {
  CLoop *_pInstance = (CLoop *)uv_loop_get_data(pLoop);
  assert(NULL != _pInstance);
  _pInstance->onSimpleCallback(nFuncIdx, pCtx);
}

void CLoop::onContextCallback(uv_loop_t *pLoop, int nFuncIdx, void *pCtx,
                              void *pCallbacCtx, int status) {
  CLoop *_pInstance = (CLoop *)uv_loop_get_data(pLoop);
  assert(NULL != _pInstance);
  _pInstance->onContextCallback(nFuncIdx,pCtx,pCallbacCtx,status);
}


bool CLoop::close(){
  assert(NULL != _pCtx);
  return uv_loop_close(_pCtx);
}

int CLoop::run(){
  assert(NULL != _pCtx);
  return uv_run(_pCtx, UV_RUN_DEFAULT);
}

void CLoop::stop(){
  assert(NULL != _pCtx);
  uv_stop(_pCtx);
}
