"""Explicit browser-requested raster limits; ordinary Paint Preview is unchanged."""


def patches():
    root = "components/services/paint_preview_compositor/"
    mojom = root + "public/mojom/paint_preview_compositor.mojom"
    impl = root + "paint_preview_compositor_impl.cc"
    return [
        (mojom, 'import "mojo/public/mojom/base/proto_wrapper.mojom";',
         'import "mojo/public/mojom/base/proto_wrapper.mojom";\n'
         'import "mojo/public/mojom/base/time.mojom";'),
        (mojom, "  map<mojo_base.mojom.UnguessableToken, SerializedRecording> recording_map;",
         "  map<mojo_base.mojom.UnguessableToken, SerializedRecording> recording_map;\n"
         "  // Arx: browser-owned full-document request only. Null ticks keep upstream behavior.\n"
         "  mojo_base.mojom.TimeTicks arx_document_deadline;\n"
         "  uint32 arx_document_width = 0;\n"
         "  uint32 arx_document_height = 0;"),
        (mojom, "    kAllocFailed = 2,", "    kAllocFailed = 2,\n"
         "    kArxLimit = 3,\n    kArxTimeout = 4,"),
        (root + "paint_preview_compositor_impl.h", "  sk_sp<SkPicture> root_frame_;",
         "  sk_sp<SkPicture> root_frame_;\n"
         "  uint32_t arx_document_width_ = 0;\n"
         "  uint32_t arx_document_height_ = 0;\n"
         "  base::TimeTicks arx_document_deadline_;"),
        (root + "paint_preview_compositor_impl.h", '#include "base/functional/callback.h"',
         '#include "base/functional/callback.h"\n#include "base/time/time.h"'),
        (impl, '#include "base/logging.h"', '#include "base/logging.h"\n'
         '#include "components/services/paint_preview_compositor/arx_raster_allocator.h"'),
        (impl, "    float scale_factor) {\n  TRACE_EVENT0(\"paint_preview\", \"PaintPreviewCompositorImpl::CreateBitmap\");",
         "    float scale_factor,\n"
         "    std::shared_ptr<arx::document::RasterState> arx_state) {\n"
         "  TRACE_EVENT0(\"paint_preview\", \"PaintPreviewCompositorImpl::CreateBitmap\");"),
        (impl, "  SkBitmap bitmap;\n  if (!bitmap.tryAllocPixels(",
         "  if (arx_state) {\n"
         "    if (scale_factor != 1.f || clip_rect.x() || clip_rect.y() ||\n"
         "        clip_rect.width() != arx_state->width || clip_rect.height() != arx_state->height) {\n"
         "      arx_state->Fail(arx::document::RasterStatus::kLimit);\n"
         "      return std::nullopt;\n"
         "    }\n"
         "    SkMatrix matrix;\n"
         "    matrix.setIdentity();\n"
         "    const auto props = skia::LegacyDisplayGlobals::GetSkSurfaceProps();\n"
         "    return arx::document::RasterPicture(*skp, matrix, arx_state, &props);\n"
         "  }\n"
         "  SkBitmap bitmap;\n  if (!bitmap.tryAllocPixels("),
        (impl, "                     frame_it->second.skp, clip_rect, scale_factor),",
         "                     frame_it->second.skp, clip_rect, scale_factor, nullptr),"),
        (impl, '               "PaintPreviewCompositorImpl::BeginMainFrameComposite");\n  frames_.clear();',
         '               "PaintPreviewCompositorImpl::BeginMainFrameComposite");\n'
         "  arx_document_width_ = request->arx_document_width;\n"
         "  arx_document_height_ = request->arx_document_height;\n"
         "  arx_document_deadline_ = request->arx_document_deadline;\n"
         "  frames_.clear();"),
        (impl, "  DCHECK(paint_preview.has_value());\n  std::optional<base::UnguessableToken> maybe_root_frame_guid =",
         "  if (!arx_document_deadline_.is_null() || arx_document_width_ || arx_document_height_) {\n"
         "    const bool valid = !arx_document_deadline_.is_null() &&\n"
         "        arx_document_deadline_ > base::TimeTicks::Now() &&\n"
         "        arx_document_deadline_ <= base::TimeTicks::Now() + base::Seconds(10) &&\n"
         "        arx_document_width_ > 0 && arx_document_width_ <= 8192 &&\n"
         "        arx_document_height_ > 0 && arx_document_height_ <= 8192 &&\n"
         "        static_cast<uint64_t>(arx_document_width_) * arx_document_height_ <= 16 * 1024 * 1024;\n"
         "    if (!valid) {\n"
         "      root_frame_.reset();\n"
         "      response->root_frame_guid = base::UnguessableToken::Create();\n"
         "      std::move(callback).Run(mojom::PaintPreviewCompositor::BeginCompositeStatus::kCompositingFailure, std::move(response));\n"
         "      return;\n"
         "    }\n"
         "  }\n"
         "  DCHECK(paint_preview.has_value());\n  std::optional<base::UnguessableToken> maybe_root_frame_guid ="),
        (impl, "  base::ThreadPool::PostTaskAndReplyWithResult(\n      FROM_HERE,\n"
         "      {base::TaskPriority::USER_VISIBLE, base::WithBaseSyncPrimitives(),\n"
         "       base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},\n"
         "      base::BindOnce(&CreateBitmap, discardable_shared_memory_manager_,\n"
         "                     root_frame_, clip_rect, scale_factor),",
         "  auto arx_state = arx_document_deadline_.is_null() ? nullptr\n"
         "      : std::make_shared<arx::document::RasterState>(\n"
         "            arx_document_width_, arx_document_height_, arx_document_deadline_);\n"
         "  base::ThreadPool::PostTaskAndReplyWithResult(\n      FROM_HERE,\n"
         "      {base::TaskPriority::USER_VISIBLE, base::WithBaseSyncPrimitives(),\n"
         "       base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},\n"
         "      base::BindOnce(&CreateBitmap, discardable_shared_memory_manager_,\n"
         "                     root_frame_, clip_rect, scale_factor, arx_state),"),
        (impl, "          [](BitmapForMainFrameCallback callback,\n"
         "             const std::optional<SkBitmap>& maybe_bitmap) {\n"
         "            if (!maybe_bitmap.has_value()) {",
         "          [](BitmapForMainFrameCallback callback,\n"
         "             std::shared_ptr<arx::document::RasterState> arx_state,\n"
         "             const std::optional<SkBitmap>& maybe_bitmap) {\n"
         "            if (arx_state && !arx_state->Continue()) {\n"
         "              using S = arx::document::RasterStatus;\n"
         "              auto status = arx_state->status.load();\n"
         "              std::move(callback).Run(status == S::kLimit\n"
         "                  ? mojom::PaintPreviewCompositor::BitmapStatus::kArxLimit\n"
         "                  : status == S::kTimeout\n"
         "                  ? mojom::PaintPreviewCompositor::BitmapStatus::kArxTimeout\n"
         "                  : mojom::PaintPreviewCompositor::BitmapStatus::kAllocFailed, SkBitmap());\n"
         "              return;\n"
         "            }\n"
         "            if (!maybe_bitmap.has_value()) {"),
        (impl, "          std::move(callback)));\n}\n\nvoid PaintPreviewCompositorImpl::SetRootFrameUrl",
         "          std::move(callback), arx_state));\n}\n\nvoid PaintPreviewCompositorImpl::SetRootFrameUrl"),
    ]
