#ifndef ARX_DOCUMENT_ENCODING_PEERS_H_
#define ARX_DOCUMENT_ENCODING_PEERS_H_
#include "document_resource_peers.h"
#include <atomic>
#include <span>
#include <utility>

class SkWStream {
 public:
  virtual ~SkWStream() = default;
  virtual bool write(const void*, size_t) = 0;
  virtual size_t bytesWritten() const = 0;
};
class SkPixmap {
 public:
  int width_value = 4, height_value = 4;
  int width() const { return width_value; }
  int height() const { return height_value; }
};
class SkBitmap {
 public:
  SkPixmap pixels;
  size_t row_bytes = 16;
  SkColorType color = kN32_SkColorType;
  bool resident = true;
  int width() const { return pixels.width(); }
  int height() const { return pixels.height(); }
  size_t rowBytes() const { return row_bytes; }
  SkColorType colorType() const { return color; }
  bool peekPixels(SkPixmap* output) const { *output = pixels; return resident; }
};
struct EncodingControl {
  static inline int factories = 0, rows = 0;
  static inline bool timeout_after_row = false;
  static inline std::atomic<bool>* cancel_after_row = nullptr;
  static void Reset() {
    factories = rows = 0; timeout_after_row = false; cancel_after_row = nullptr;
    base::TimeTicks::now = 0;
  }
};
class SkEncoder {
 public:
  explicit SkEncoder(SkWStream* stream) : stream_(stream) {}
  bool encodeRows(int count) {
    assert(count == 1);
    ++EncodingControl::rows;
    if (EncodingControl::timeout_after_row) base::TimeTicks::now = 100;
    if (EncodingControl::cancel_after_row) EncodingControl::cancel_after_row->store(true);
    return stream_->write("12345678", 8);
  }
 private:
  SkWStream* stream_;
};
namespace SkPngRustEncoder {
struct Options {};
inline std::unique_ptr<SkEncoder> Make(SkWStream* stream, const SkPixmap&, const Options&) {
  ++EncodingControl::factories;
  if (!stream->write("PNG", 3)) return {};
  return std::make_unique<SkEncoder>(stream);
}
}
#endif
