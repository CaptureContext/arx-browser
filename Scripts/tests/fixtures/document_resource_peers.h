#ifndef ARX_DOCUMENT_RESOURCE_PEERS_H_
#define ARX_DOCUMENT_RESOURCE_PEERS_H_
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace base {
class TimeTicks {
 public:
  static inline int64_t now = 0;
  static TimeTicks Now() { return TimeTicks(now); }
  explicit TimeTicks(int64_t value) : value_(value) {}
  bool operator<(const TimeTicks& other) const { return value_ < other.value_; }
  bool operator>=(const TimeTicks& other) const { return value_ >= other.value_; }
 private:
  int64_t value_;
};
}
namespace arx::document::mojom {
enum class Status { kSuccess, kLimit, kUnsupported, kTimeout, kCancelled, kFailed };
struct Limits {
  uint32_t maximum_dimension = 8192;
  uint64_t maximum_pixels = 16 * 1024 * 1024;
  uint64_t maximum_serialized_bytes = 32 * 1024 * 1024;
  uint64_t maximum_png_bytes = 64 * 1024 * 1024;
  uint32_t timeout_ms = 3000;
  uint64_t maximum_record_ops = 100;
  uint64_t maximum_record_bytes = 1024;
  uint64_t maximum_decoded_image_bytes = 256;
};
}
enum SkColorType { kUnknown_SkColorType, kN32_SkColorType, kAlpha_8_SkColorType };
using SkFontTableTag = uint32_t;
class SkTypeface {
 public:
  uint32_t id = 1;
  int tables = 1;
  size_t table_size = 8;
  uint32_t uniqueID() const { return id; }
  int countTables() const { return tables; }
  struct Tags { SkFontTableTag* tags; size_t count; };
  int readTableTags(Tags output) const {
    for (size_t index = 0; index < output.count; ++index) output.tags[index] = index;
    return tables;
  }
  size_t getTableSize(SkFontTableTag) const { return table_size; }
  void openStream() const = delete;
};
class SkTextBlob {
 public:
  std::vector<int> glyphs;
  SkTypeface typeface;
  class Iter {
   public:
    struct Run { SkTypeface* fTypeface; int fGlyphCount; };
    explicit Iter(const SkTextBlob& blob) : blob_(blob) {}
    bool next(Run* run) {
      if (index_ == blob_.glyphs.size()) return false;
      run->fGlyphCount = blob_.glyphs[index_++]; run->fTypeface = const_cast<SkTypeface*>(&blob_.typeface); return true;
    }
   private:
    const SkTextBlob& blob_;
    size_t index_ = 0;
  };
};
inline constexpr float SK_ScalarInfinity = __builtin_inff();
namespace cc {
enum class PaintOpType {
  kAnnotate, kClipPath, kClipRect, kClipRRect, kConcat, kCustomData, kDrawArc,
  kDrawArcLite, kDrawColor, kDrawDRRect, kDrawImage, kDrawImageRect, kDrawIRect,
  kDrawLine, kDrawLineLite, kDrawOval, kDrawPath, kDrawRecord, kDrawRect, kDrawRRect,
  kDrawScrollingContents, kDrawSkottie, kDrawSlug, kDrawTextBlob, kDrawTextSlugs,
  kDrawVertices, kNoop, kRestore, kRotate, kSave, kSaveLayer, kSaveLayerAlpha,
  kSaveLayerFilters, kScale, kSetMatrix, kSetNodeId, kTranslate
};
struct PaintOp {
  explicit PaintOp(PaintOpType type, bool flags = false) : type(type), flags(flags) {}
  PaintOpType GetType() const { return type; }
  bool IsPaintOpWithFlags() const { return flags; }
  PaintOpType type; bool flags;
};
struct SaveLayerAlphaOp : PaintOp {
  SaveLayerAlphaOp() : PaintOp(PaintOpType::kSaveLayerAlpha) {}
  struct Bounds {
    float left() const { return 0; }
    float top() const { return 0; }
    float right() const { return 8; }
    float bottom() const { return 8; }
  } bounds;
  float alpha = 1;
  bool valid = true;
  bool IsValid() const { return valid; }
};
struct PaintShader {
  enum class Type { kColor, kLinearGradient, kRadialGradient, kImage, kPaintRecord };
  Type type = Type::kImage;
  Type shader_type() const { return type; }
};
struct PaintFlags {
  // `shader` attaches `shader_value`, an image shader unless a test picks another type.
  bool shader = false, filter = false, path = false, color = false, looper = false;
  PaintShader shader_value;
  bool HasShader() const { return shader; }
  const PaintShader* getShader() const { return shader ? &shader_value : nullptr; }
  bool getImageFilter() const { return filter; }
  bool getPathEffect() const { return path; }
  bool getColorFilter() const { return color; }
  bool getLooper() const { return looper; }
};
struct PaintOpWithFlags : PaintOp {
  explicit PaintOpWithFlags(PaintOpType type) : PaintOp(type, true) {}
  PaintFlags flags;
};
struct PaintRecord {
  size_t bytes = 32, operations = 1;
  std::vector<const PaintOp*> ops;
  size_t bytes_used() const { return bytes; }
  size_t total_op_count() const { return operations; }
  struct Iterator {
    std::vector<const PaintOp*>::const_iterator it;
    const PaintOp& operator*() const { return **it; }
    Iterator& operator++() { ++it; return *this; }
    bool operator!=(const Iterator& other) const { return it != other.it; }
  };
  Iterator begin() const { return {ops.begin()}; }
  Iterator end() const { return {ops.end()}; }
};
class PaintImage {
 public:
  bool deferred = false, lazy = false, animated = false, gainmap = false;
  int width = 8, height = 8, bytes = 4;
  SkColorType color = kN32_SkColorType;
  bool IsDeferredPaintRecord() const { return deferred; }
  bool IsLazyGenerated() const { return lazy; }
  bool ShouldAnimate() const { return animated; }
  bool HasGainmapInfo() const { return gainmap; }
  struct Info {
    const PaintImage& image;
    SkColorType colorType() const { return image.color; }
    int width() const { return image.width; }
    int height() const { return image.height; }
    int bytesPerPixel() const { return image.bytes; }
  };
  Info GetSkImageInfo() const { return {*this}; }
  // A compile trap if admission attempts expensive pixel access.
  void GetSwSkImage() const = delete;
  void readPixels() const = delete;
};
struct DrawImageOp : PaintOpWithFlags {
  DrawImageOp() : PaintOpWithFlags(PaintOpType::kDrawImage) {}
  PaintImage image;
};
struct DrawImageRectOp : PaintOpWithFlags {
  DrawImageRectOp() : PaintOpWithFlags(PaintOpType::kDrawImageRect) {}
  PaintImage image;
};
struct DrawRecordOp : PaintOp {
  DrawRecordOp() : PaintOp(PaintOpType::kDrawRecord) {}
  PaintRecord record;
};
struct Path {
  uint64_t bytes = 1;
  uint64_t approximateBytesUsed() const { return bytes; }
};
struct ClipPathOp : PaintOp {
  ClipPathOp() : PaintOp(PaintOpType::kClipPath) {}
  Path path;
};
struct DrawPathOp : PaintOpWithFlags {
  DrawPathOp() : PaintOpWithFlags(PaintOpType::kDrawPath) {}
  Path path;
};
struct DrawTextBlobOp : PaintOpWithFlags {
  DrawTextBlobOp() : PaintOpWithFlags(PaintOpType::kDrawTextBlob) {}
  std::shared_ptr<SkTextBlob> blob;
};
}
#endif
