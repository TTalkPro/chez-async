#include "cbuffer.h"
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

#define CBUFFER_BLOCK_SIZE 1024       // 默认为1kb
#define CBUFFER_BLOCK_MASK 0xFFFFFC00 // 将数据进行round操作，最大4G
#define CBUFFER_MAX_SIZE 0xFFFFFFFF

CBuffer::CBuffer()
    :_pBuffer(NULL), _nBuffer(0), _nLength(0) {
  _pNext = this;
  _pPrev = this;
}

CBuffer::~CBuffer() {
  if (_pBuffer)
    free(_pBuffer);
}

void CBuffer::add(const void *pData, const size_t nLength) {
  if (NULL == pData)
    return;

  if (!ensure(nLength))
    return;
  memcpy(_pBuffer + _nLength, pData, nLength);
  _nLength += nLength;
}

void CBuffer::insert(const size_t nOffset, const void *pData,
                     const size_t nLength) {
  if (NULL == pData)
    return;

  if (!ensure(nLength))
    return;
  // 如果offset已经大于了长度，就不需要移动了
  // 之中情况是不应该出现了
  assert((_nLength >= nOffset));
  if (_nLength > nOffset) {
    // 先移动数据，得到相应的空间
    memmove(_pBuffer + nOffset + nLength, _pBuffer + nOffset,
            _nLength - nOffset);
  }
  // 插入数据
  memcpy(_pBuffer + nOffset, pData, nLength);
  _nLength += nLength;
}

void CBuffer::remove(const size_t nLength) {
  if (nLength >= _nLength) {
    _nLength = 0;
  } else if (nLength) {
    _nLength -= nLength;
    memmove(_pBuffer, _pBuffer + nLength, _nLength);
  }
}

size_t CBuffer::addBuffer(CBuffer *pBuffer, const size_t nLength) {
  assert(pBuffer && pBuffer != this);
  if (NULL == pBuffer || this == pBuffer)
    return 0;

  // 最大4G
  if (nLength > INT32_MAX)
    return 0;
  if (pBuffer->_nLength < nLength) {
    add(pBuffer->_pBuffer, pBuffer->_nLength);
    size_t _nBufferLength = _nLength;
    pBuffer->clear();
    return _nBufferLength;
  } else {
    add(pBuffer->_pBuffer, nLength);
    pBuffer->remove(nLength);
    return nLength;
  }
}

void CBuffer::attach(CBuffer *pBuffer) {
  assert(pBuffer && pBuffer != this);
  if (NULL == pBuffer || this == pBuffer)
    return;

  if (_pBuffer)
    free(_pBuffer);
  _pBuffer = pBuffer->_pBuffer;
  pBuffer->_pBuffer = NULL;

  _nBuffer = pBuffer->_nBuffer;
  pBuffer->_nBuffer = 0;

  _nLength = pBuffer->_nLength;
  pBuffer->_nLength = 0;
}

void CBuffer::addReversed(const void *pData, const size_t nLength) {
  if (NULL == pData)
    return;

  if (!ensure(nLength))
    return;

  reverseBuffer(pData, _pBuffer + _nLength, nLength);

  _nLength += nLength;
}

bool CBuffer::ensure(const size_t nLength) {
  if (nLength > CBUFFER_MAX_SIZE - _nBuffer)
    return false;

  if (_nBuffer - _nLength >= nLength) {
    // 分配了512KB，但是实际使用不足256KB
    // 让内存进行缩小
    if (_nBuffer > 0x80000 && _nLength + nLength < 0x40000) {
      const size_t nBuffer = 0x40000;
      char *pBuffer = (char *)realloc(_pBuffer, nBuffer);
      // 虽然重新定位失败，但是内存空间的大小是足够的
      if (!pBuffer)
        return true;
      _nBuffer = nBuffer;
      _pBuffer = pBuffer;
    }
    return true;
  }

  size_t nBuffer = _nLength + nLength;
  // 获取最合适的大小
  nBuffer = (nBuffer + CBUFFER_BLOCK_SIZE - 1) & CBUFFER_BLOCK_MASK;

  char *pBuffer = (char *)realloc(_pBuffer, nBuffer);
  if (!pBuffer)
    return false;
  _nBuffer = nBuffer;
  _pBuffer = pBuffer;
  return true;
}

size_t CBuffer::read(void *pData, const size_t nLength) {
  size_t nExpectLength = nLength;
  // 如果buffer数据小于想要的，直接全读取了
  if (nLength > _nLength)
    nExpectLength = _nLength;
  memcpy(pData, _pBuffer, nExpectLength);
  if(nExpectLength == _nLength){
    _nLength = 0;
  }else{
    remove(nExpectLength);
  }
  return nExpectLength;
}

bool CBuffer::readNBytes(void *pData, const size_t nLength) {
  if (nLength > _nLength)
    return false;
  this->read(pData, nLength);
  return true;
}

bool CBuffer::readLine(std::string &refStr, bool bPeek) {

  if (0 == _nLength)
    return false;

  size_t nIndex = 0;

  // 寻找\n
  for (; nIndex < _nLength; nIndex++) {
    if (_pBuffer[nIndex] == '\n')
      break;
  }

  if (nIndex >= _nLength)
    return false;

  if (nIndex > 0)
    refStr.append(_pBuffer, nIndex);

  if (!bPeek) {
    remove(nIndex + 1);
  }

  return true;
}

void CBuffer::reverseBuffer(const void *pInput, void *pOutput, size_t nLength) {
  if (nLength) {
    const char *pInputBytes = (const char *)pInput + nLength;
    char *pOutputBytes = (char *)pOutput;
    while (nLength--) {
      *pOutputBytes++ = *--pInputBytes;
    }
  }
}
