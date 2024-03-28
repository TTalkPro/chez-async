#include "cloop.h"
#include <uv.h>

#define HANDLER_TYPE_UNKNOWN 0
#define HANDLER_TYPE_TCP 1
#define HANDLER_TYPE_UDP 2
#define HANDLER_TYPE_TIMER 3

class CHandler {
public:
  CHandler();
  CHandler(CLoop* pLoop);
  CHandler(CLoop* pLoop, int nType);
  ~CHandler() {_pLoop = NULL;}

private:
  CLoop *_pLoop;
  int _nType;
  bool _bInCallback;
  bool _bStarted;

protected:
  inline uv_loop_t* getUVLoop(){return _pLoop->theLoop();}
  inline CLoop* theLoop(){return _pLoop;}
  inline void setHandlerType(int nType){_nType = nType;}
  inline void enterCallback() { _bInCallback = true; }
  inline void leaveCallback() { _bInCallback = false; }
  inline bool isInCallback() {return _bInCallback;}
  inline void start(){_bStarted = true;}
  inline void stop() {_bStarted = false;}
  inline bool isStarted() {return _bStarted;}
  virtual void onAllocBuffer(uv_handle_t *handle, size_t suggested_size,
                             uv_buf_t *buf) = 0;

public:
  inline int getHandlerType(){return _nType;}
  static void onAllocBufferCallback(uv_handle_t *handle, size_t suggested_size,
                                    uv_buf_t *buf);
};
