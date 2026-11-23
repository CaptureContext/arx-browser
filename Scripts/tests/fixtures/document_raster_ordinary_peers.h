#include <cassert>
#include <memory>
#include <optional>
#define TRACE_EVENT0(a,b)
template<class T> using scoped_refptr = std::shared_ptr<T>;
template<class T> using sk_sp = std::shared_ptr<T>;
namespace discardable_memory { struct ClientDiscardableSharedMemoryManager {}; }
namespace gfx {
struct Rect {
  int left, top, width_, height_;
  int x() const { return left; } int y() const { return top; }
  int width() const { return width_; } int height() const { return height_; }
};
}
struct SkMatrix {
  float scale_x=0, scale_y=0, translate_x=0, translate_y=0;
  void setScaleTranslate(float x,float y,float tx,float ty) { scale_x=x;scale_y=y;translate_x=tx;translate_y=ty; }
  void setIdentity() { setScaleTranslate(1,1,0,0); }
};
struct SkPicture { int cullRect() const { return 1; } };
struct SkImageInfo {
  int width,height;
  static SkImageInfo MakeN32Premul(int width,int height) { return {width,height}; }
};
inline bool allocation_allowed = true;
inline int allocations = 0, ordinary_draws = 0, capture_draws = 0;
inline SkMatrix actual_matrix;
struct SkBitmap {
  int width=0,height=0;
  bool tryAllocPixels(SkImageInfo info) {
    ++allocations; width=info.width;height=info.height;return allocation_allowed;
  }
};
namespace skia {
struct LegacyDisplayGlobals { static const int& GetSkSurfaceProps() { static int props=0;return props; } };
}
struct SkCanvas {
  SkCanvas(const SkBitmap&,int) {}
  void drawPicture(sk_sp<SkPicture>,const SkMatrix* matrix,void*) { ++ordinary_draws;actual_matrix=*matrix; }
};
namespace arx::document {
enum class RasterStatus { kLimit };
struct RasterState { int width,height;bool failed=false;void Fail(RasterStatus) { failed=true; } };
inline std::optional<SkBitmap> RasterPicture(const SkPicture&,const SkMatrix&,
    const std::shared_ptr<RasterState>& state,const int*) {
  ++capture_draws;return SkBitmap{state->width,state->height};
}
}
inline gfx::Rect AdjustClipRect(const gfx::Rect& rect,int,float) { return rect; }
