#include "ctcp.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <uv.h>
#include <uv/unix.h>

CTcp::CTcp(uv_loop_t *pLoop) : CTcp(pLoop, NULL) {}
CTcp::CTcp(uv_loop_t *pLoop, uv_tcp_t *pCtx) : _pLoop(pLoop), _pCtx(pCtx),_bInCallback(false) {
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

void CTcp::regiserCallback(void *pOnConnect, void *pOnConnection,
                           void *pOnShutDown, void *pOnRead, void *pOnWrite){
  _aCallbacks[0] = (CTcpCallback)pOnConnect;
  _aCallbacks[1] = (CTcpCallback)pOnConnection;
  _aCallbacks[2] = (CTcpCallback)pOnShutDown;
  _aCallbacks[3] = (CTcpCallback)pOnRead;
  _aCallbacks[4] = (CTcpCallback)pOnWrite;
}

void CTcp::onConnection(uv_stream_t *req, int status){
  _bInCallback = true;
  CTcpCallback _callback = _aCallbacks[1];
  if (status < 0) {
    _callback(this,status);
    _bInCallback = false;
    return;
  }
  uv_tcp_t *_client = (uv_tcp_t *)malloc(sizeof(uv_tcp_t));
  uv_tcp_init(this->_pLoop, _client);
  CTcp *_pCTcp = new CTcp(this->_pLoop, _client);
  if (uv_accept(req, (uv_stream_t *)_client) == 0) {
    _callback(_pCTcp,status);
  }
  _bInCallback = false;
}

void CTcp::onConnect(uv_connect_t *req, int status) {
  _bInCallback = true;
  CTcpCallback _callback = _aCallbacks[1];
  _callback(this, status);
  _bInCallback = false;
}

void CTcp::onShutdown(uv_shutdown_t* req, int status){
  _bInCallback = true;
  CTcpCallback _callback = _aCallbacks[2];
  _callback(this,status);
  _bInCallback = false;
  delete this;
}
void CTcp::onRead(uv_stream_t* req, ssize_t nread,const uv_buf_t* buf){
  _bInCallback = true;
  CTcpCallback _callback = _aCallbacks[3];
  _callback(this,nread);
  _bInCallback = false;
}

void CTcp::onWrite(uv_write_t *req,int status){
  _bInCallback = true;
  CTcpCallback _callback = _aCallbacks[4];
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
  _callback(this, status);
  if(req != &_sWriteReq){
    free(req);
  }
  _bInCallback = false;
}

void CTcp::onAllocBuffer(uv_handle_t *handle, size_t suggested_size,uv_buf_t *buf){
  _pRBuffer->ensure(suggested_size);
  buf->base = _pRBuffer->getDataEnd();
  buf->len = _pRBuffer->getFreeLength();
}

void CTcp::onConnectionCallback(uv_stream_t *stream, int status){
  CTcp *pInstance = (CTcp *)stream->data;
  pInstance->onConnection(stream,status);
}
void CTcp::onConnectCallback( uv_connect_t *req, int status){
  CTcp *pInstance = (CTcp *)req->data;
  pInstance->onConnect(req,status);
}
void CTcp::onShutdownCallback( uv_shutdown_t *req, int status){
  CTcp *pInstance = (CTcp *)req->data;
  pInstance->onShutdown(req,status);
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

void CTcp::onAllocBufferCallback(uv_handle_t *handle,
                         size_t suggested_size, uv_buf_t *buf){
  CTcp *pInstance = (CTcp *)handle->data;
  pInstance->onAllocBuffer(handle,suggested_size,buf);
}

bool CTcp::doListen(char* pAddr,int nPort,int backlog){
  _pCtx = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
  uv_tcp_init(_pLoop, _pCtx);
  uv_ip4_addr(pAddr, nPort, &_sAddr);
  uv_tcp_bind(_pCtx, (const struct sockaddr *)&_sAddr, 0);
  _pCtx->data = this;
  int r = uv_listen((uv_stream_t *)_pCtx, backlog,CTcp::onConnectionCallback);
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
  uv_tcp_init(_pLoop, _pCtx);
  memset(&_sConnectReq, 0, sizeof(uv_connect_t));
  _sConnectReq.data = this;
  uv_ip4_addr(pAddr,nPort, &_sAddr);
  int r = uv_tcp_connect(&_sConnectReq, _pCtx, (const struct sockaddr *)&_sAddr, CTcp::onConnectCallback);
  if(r){
    return false;
  }
  return true;
}
