#include <cstddef>
#include <cstdint>
#include <string>

class CBuffer {

public:
  CBuffer();
  ~CBuffer();
  CBuffer *_pNext;

private:
  char *_pBuffer; //buffer本体
  size_t _nLength; // 使用了多少
  size_t _nBuffer; // buffer总大小

  CBuffer(const CBuffer &);
  CBuffer &operator=(const CBuffer &);

public:
  inline size_t getBufferSize() const { return _nBuffer; }
  inline char *getData() const { return _pBuffer; }
  inline size_t getLength() const { return _nLength; }
  inline char *getDataEnd() const { return _pBuffer + _nLength; }
  // 返回剩余多少空间
  inline size_t getBufferFree() const { return _nBuffer - _nLength; }

public:
  void add(const void *pData, const size_t nLength);
  // 将数据插入指定的位置
  void insert(const size_t nOffset, const void *pData, const size_t nLength);
  void remove(const size_t nLength);
  //将另外一个buffer添加到当前buffer中
  size_t addBuffer(CBuffer *pBuffer,const size_t nLength);
  //确保有足够多的内存
  bool  ensure(const size_t nLength);
  void addReversed(const void *pData,const size_t nLength);
  //用另外一个buffer直接替换当前buffer
  void attach(CBuffer *pBuffer);

public:
  //有多少读取多少
  size_t read(void *pData, const size_t nLength);
  //精确的读取
  bool readNBytes(void *pData, const size_t nLength);
  //读取一行，不包含\n
  bool readLine(std::string &str,bool bPeek);
public:
  //清除内容
  inline void clear() throw() {_nLength = 0; }

  size_t addBuffer(CBuffer *pBuffer) {
    return addBuffer(pBuffer, pBuffer->_nLength);
  }

  void prefix(char* pStr, const size_t nLength) {
    insert(0, (void *)pStr, nLength);
  }

public:
  static void reverseBuffer(const void *pInput, void *pOutput, size_t nLength);
};
