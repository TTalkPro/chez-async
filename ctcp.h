#include "cbuffer.h"
#include "chandler.h"
#include <cstddef>
#include <uv.h>
class CTcp : public CHandler {

public:
  CTcp(CLoop *pLoop);
  CTcp(CLoop *pLoop, uv_tcp_t *pCtx);
  ~CTcp();

private:
  uv_tcp_t *_pCtx;
  CBuffer *_pRBuffer;
  CBuffer *_pWBuffer;
  uv_write_t _sWriteReq;
  uv_shutdown_t _sShutdownReq;
  uv_connect_t _sConnectReq;
  struct sockaddr_in _sAddr;

private:
  void onRead(uv_stream_t *req, ssize_t nread, const uv_buf_t *buf);
  void onWrite(uv_write_t *req, int status);
  void onAccepted(uv_stream_t *req, int status);

protected :

void onAllocBuffer(uv_handle_t *handle, size_t suggested_size,
                                     uv_buf_t *buf);

public:
  inline uv_tcp_t *getContext() const { return _pCtx; }

public:
  // libuv 回调用的函数
  static void onAcceptedCallback(uv_stream_t *req, int status);
  static void onConnectedCallback(uv_connect_t *req, int status);
  static void onShutdownCallback(uv_shutdown_t *req, int status);
  static void onReadCallback(uv_stream_t *stream, ssize_t nread,
                             const uv_buf_t *buf);
  static void onWriteCallback(uv_write_t *req, int status);


public:
  bool doListen(char *pAddr, int nPort, int backlog);
  bool doListen(char *pAddr, int nPort);
  bool doConnect(char *pAddr, int nPort);
  // void doRewrite();
  // void doWrite(char* pData,size_t nLength);
  // size_t doRead(char* pData,size_t nLength);
  // bool doShutdown();
};
