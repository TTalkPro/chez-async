#include <cstddef>
#include <uv.h>
#include "cbuffer.h"
class CTcp {
  typedef void (*CTcpCallback)(void*,int);
public:
  CTcp(uv_loop_t* pLoop);
  CTcp(uv_loop_t *pLoop, uv_tcp_t* pCtx);
  ~CTcp();

private:
  uv_tcp_t* _pCtx;
  uv_loop_t* _pLoop;
  CBuffer* _pRBuffer;
  CBuffer* _pWBuffer;
  CTcpCallback _aCallbacks[5];
  bool _bInCallback;
  uv_write_t _sWriteReq;
  uv_shutdown_t _sShutdownReq;
  uv_connect_t _sConnectReq;
  struct sockaddr_in _sAddr;

  void onConnection(uv_stream_t *req, int status);
  void onConnect(uv_connect_t *req, int status);
  void onShutdown(uv_shutdown_t *req, int status);
  void onRead(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf);
  void onWrite(uv_write_t *req, int status);
  void onAllocBuffer(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf);

public:
  inline uv_tcp_t* getContext() const {return _pCtx;}
  void regiserCallback(void* pOnConnect,
                       void* pOnConnection,
                       void* pOnShutDown,
                       void* pOnRead,
                       void* pOnWrite);
public:
  //libuv 回调用的函数
  static void onConnectionCallback(uv_stream_t *req, int status);
  static void onConnectCallback(uv_connect_t *req, int status);
  static void onShutdownCallback(uv_shutdown_t *req, int status);
  static void onReadCallback(uv_stream_t *stream, ssize_t nread,
                     const uv_buf_t *buf);
  static void onWriteCallback(uv_write_t *req, int status);
  static void onAllocBufferCallback(uv_handle_t *handle, size_t
                                    suggested_size, uv_buf_t *buf);


public:
  bool doListen(char *pAddr, int nPort,int backlog);
  bool doListen(char *pAddr, int nPort);
  bool doConnect(char* pAddr,int nPort);
  // void doRewrite();
  // void doWrite(char* pData,size_t nLength);
  // size_t doRead(char* pData,size_t nLength);
  // bool doShutdown();
};
