#include "ctcp.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <uv.h>
#include <uv/unix.h>

CTcp::CTcp(CLoop *pLoop) : CTcp(pLoop, NULL) {}
CTcp::CTcp(CLoop *pLoop, uv_tcp_t *pCtx) :CHandler(pLoop, HANDLER_TYPE_TCP), _pCtx(pCtx){
  std::bad_alloc exception;
  _pRBuffer  = new CBuffer();
  if(NULL == _pRBuffer){
    throw exception;
  }
  _pWBuffer = new CBuffer();
  if(NULL == _pWBuffer){
    delete _pRBuffer;
    _pRBuffer = NULL;
    throw exception;
  }else {
    _pWBuffer->_pNext = _pWBuffer;
    _pWBuffer->_pPrev = _pWBuffer;
  }
}

CTcp::~CTcp(){
  if(NULL != _pRBuffer){
    delete _pRBuffer;
  }
  if(NULL != _pWBuffer){
    delete _pWBuffer;
  }
  if(NULL != _pCtx){
    free(_pCtx);
  }
  _pRBuffer = NULL;
  _pWBuffer = NULL;
  _pCtx = NULL;
}

void CTcp::onAccepted(uv_stream_t *req, int status){
  enterCallback();
  if (status < 0) {
    theLoop()->onStatusCallback(STATUS_FUNC_ON_ACCEPTED, NULL, status);
    leaveCallback();
    return;
  }
  uv_tcp_t *_client = (uv_tcp_t *)malloc(sizeof(uv_tcp_t));
  uv_tcp_init(getUVLoop(), _client);
  CTcp *_pCTcp = new CTcp(theLoop(), _client);
  if (uv_accept(req, (uv_stream_t *)_client) == 0) {
    theLoop()->onStatusCallback(STATUS_FUNC_ON_ACCEPTED, _pCTcp, status);
  }
  leaveCallback();

}

void CTcp::onRead(uv_stream_t* req, ssize_t nread,const uv_buf_t* buf){
  enterCallback();
  if(nread > 0){
    _pRBuffer->increaseLength(nread);
  }
  theLoop()->onStatusCallback(STATUS_FUNC_ON_READ, this, nread);
  leaveCallback();
}

void CTcp::onWrite(uv_write_t *req,int status){
  enterCallback();
  if(status == 0){
    //出现连续写的情况
    if(_pWBuffer->_pNext != _pWBuffer){
      CBuffer* _current = _pWBuffer; //取队列头
      _pWBuffer = _current->_pNext; //将队列第二位升级为队列头
      _pWBuffer->_pPrev = _current->_pPrev;
      _current->_pPrev->_pNext = _pWBuffer;//队列尾巴重新指向队列头
      delete _current;
    }else {
      //整个buffer写完了
      _pWBuffer->clear();
    }
  }
  theLoop()->onStatusCallback(STATUS_FUNC_ON_WRITE,this,status);
  if(req != &_sWriteReq){
    free(req);
  }
  leaveCallback();
}

void CTcp::onAllocBuffer(uv_handle_t *handle, size_t suggested_size,uv_buf_t *buf){
  _pRBuffer->ensure(suggested_size);
  buf->base = _pRBuffer->getDataEnd();
  buf->len = _pRBuffer->getFreeLength();
}

void CTcp::onAcceptedCallback(uv_stream_t *stream, int status){
  CTcp *_pInstance = (CTcp *)stream->data;
  _pInstance->onAccepted(stream,status);
}
void CTcp::onConnectedCallback( uv_connect_t *req, int status){
  CTcp *_pInstance = (CTcp *)req->data;
  _pInstance->enterCallback();
  _pInstance->theLoop()->onStatusCallback(STATUS_FUNC_ON_CONNECTED, _pInstance,
                                          status);
  _pInstance->leaveCallback();
}
void CTcp::onShutdownCallback( uv_shutdown_t *req, int status){
  CTcp *_pInstance = (CTcp *)req->data;
  _pInstance->enterCallback();
  _pInstance->theLoop()->onStatusCallback(STATUS_FUNC_ON_SHUTDOWN, _pInstance,
                                          status);
  _pInstance->leaveCallback();
}

void CTcp::onReadCallback(uv_stream_t *stream, ssize_t nread,
                          const uv_buf_t *buf){
  CTcp *pInstance = (CTcp *)stream->data;
  pInstance->onRead(stream,nread,buf);
}
void CTcp::onWriteCallback(uv_write_t *req, int status){
  CTcp *pInstance = (CTcp *)req->data;
  pInstance->onWrite(req,status);
}


bool CTcp::doListen(char* pAddr,int nPort,int backlog){
  _pCtx = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
  uv_tcp_init(getUVLoop(), _pCtx);
  uv_ip4_addr(pAddr, nPort, &_sAddr);
  uv_tcp_bind(_pCtx, (const struct sockaddr *)&_sAddr, 0);
  _pCtx->data = this;
  int r = uv_listen((uv_stream_t *)_pCtx, backlog,CTcp::onAcceptedCallback);
  if (r) {
    return false;
  }
  return true;
}

bool CTcp::doListen(char* pAddr,int nPort){
  return doListen(pAddr,nPort,1024);
}

bool CTcp::doConnect(char* pAddr,int nPort){
  _pCtx = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
  uv_tcp_init(getUVLoop(), _pCtx);
  memset(&_sConnectReq, 0, sizeof(uv_connect_t));
  _sConnectReq.data = this;
  uv_ip4_addr(pAddr,nPort, &_sAddr);
  int r = uv_tcp_connect(&_sConnectReq, _pCtx, (const struct sockaddr *)&_sAddr, CTcp::onConnectedCallback);
  if(r){
    return false;
  }
  return true;
}
