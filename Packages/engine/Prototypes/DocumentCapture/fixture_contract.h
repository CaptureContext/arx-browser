#ifndef ARX_DOCUMENT_PROTOTYPE_FIXTURE_CONTRACT_H_
#define ARX_DOCUMENT_PROTOTYPE_FIXTURE_CONTRACT_H_

#include <array>
#include <cstdint>
#include <cmath>
#include <span>

namespace arx::document::testing {

inline constexpr int kBandHeight = 800;
inline constexpr int kDocumentHeight = kBandHeight * 3;
inline constexpr int kScroll = 550;
inline constexpr std::array<uint32_t, 3> kColors = {0xffff0000, 0xff00ff00, 0xff0000ff};

inline bool GeometryMatchesCSS(int width, int height, double scroll_x, double scroll_y,
                               double css_width, double css_height, double css_scroll_x,
                               double css_scroll_y, double css_dpr, double device_scale,
                               double zoom_factor) {
  const double scale = device_scale * zoom_factor;
  return std::isfinite(scale) && scale > 0 && scale <= 4 &&
      std::isfinite(css_width) && css_width > 0 && css_width <= 32768 &&
      std::isfinite(css_height) && css_height > 0 && css_height <= 32768 &&
      std::abs(css_dpr - scale) < 1e-6 &&
      width == std::lround(css_width * scale) && height == std::lround(css_height * scale) &&
      std::abs(scroll_x - css_scroll_x * scale) < 1e-4 &&
      std::abs(scroll_y - css_scroll_y * scale) < 1e-4;
}

template <typename Sample>
bool SingleMarkerPixels(int bitmap_width, int bitmap_height, double document_x,
                        double document_y, double css_width, double css_height,
                        double layout_scale, Sample sample) {
  if (!std::isfinite(layout_scale) || layout_scale <= 0 || layout_scale > 4 ||
      !std::isfinite(document_x) || !std::isfinite(document_y) ||
      std::abs(document_x) > 32768 || std::abs(document_y) > 32768 ||
      css_width != 80 || css_height != 24) return false;
  const int x = std::lround((document_x + css_width / 2) * layout_scale);
  const int y = std::lround((document_y + css_height / 2) * layout_scale);
  if (css_width != 80 || css_height != 24 || x < 0 || x >= bitmap_width ||
      y < 0 || y >= bitmap_height || sample(x, y) != 0xff000000) return false;
  int black_rows = 0;
  for (int row = 0; row < bitmap_height; ++row)
    if (sample(x, row) == 0xff000000) ++black_rows;
  return black_rows == std::lround(css_height * layout_scale);
}

// Caller must supply actual PNG pixels converted to sRGB, never metadata/title
// evidence. Samples are inside each band and away from scrollbars/fixture focus.
template <typename Sample>
bool FullDocumentPixels(int width, int height, double layout_scale, Sample sample) {
  if (!std::isfinite(layout_scale) || layout_scale <= 0 || layout_scale > 4 ||
      width < 400 * layout_scale || width > 1200 * layout_scale ||
      height != std::lround(kDocumentHeight * layout_scale)) return false;
  const int band_height = std::lround(kBandHeight * layout_scale);
  for (int band = 0; band < 3; ++band) {
    if (sample(32, band * band_height + 32) != kColors[band] ||
        sample(width / 2, band * band_height + band_height / 2) != kColors[band] ||
        sample(32, (band + 1) * band_height - 32) != kColors[band]) return false;
  }
  return true;
}

using ViewportSamples = std::array<uint32_t, 9>;
template <typename Sample>
ViewportSamples ViewportPixels(int width, int height, Sample sample) {
  ViewportSamples colors;
  size_t index = 0;
  for (int y : {32, height / 2, height - 32})
    for (int x : {32, width / 4, width / 2}) colors[index++] = sample(x, y);
  return colors;
}

// Only the display-compositor readback may differ by two encoded sRGB steps
// after GPU/display color conversion. Every channel/probe is bounded; alpha is
// exact. Exported full-document PNG pixels retain their exact comparisons.
// Pinned components/viz/service/display/renderer_pixeltest.cc:4166 and
// cc/test/pixel_comparator.h use explicit per-channel absolute-error bounds.
inline bool ViewportColorMatches(uint32_t actual, uint32_t expected) {
  if ((actual >> 24) != 255 || (expected >> 24) != 255) return false;
  for (int shift : {16, 8, 0})
    if (std::abs(static_cast<int>((actual >> shift) & 255) -
                 static_cast<int>((expected >> shift) & 255)) > 2) return false;
  return true;
}

enum class RepaintObservation { kInvalidBaseline, kPending, kReady, kTimeout };
inline RepaintObservation ObserveRepaint(const ViewportSamples& before,
                                       const ViewportSamples& current,
                                       int64_t elapsed_ms) {
  for (size_t index = 0; index < 3; ++index)
    if (!ViewportColorMatches(before[index], kColors[0])) return RepaintObservation::kInvalidBaseline;
  if (elapsed_ms < 0 || elapsed_ms >= 1000) return RepaintObservation::kTimeout;
  for (size_t index = 0; index < 3; ++index)
    if (!ViewportColorMatches(current[index], 0xff00ffff)) return RepaintObservation::kPending;
  return RepaintObservation::kReady;
}

}  // namespace arx::document::testing
#endif
