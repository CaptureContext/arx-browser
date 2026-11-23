std::optional<SkBitmap> CreateBitmap(
    scoped_refptr<discardable_memory::ClientDiscardableSharedMemoryManager>
        discardable_shared_memory_manager,
    sk_sp<SkPicture> skp,
    const gfx::Rect& raw_clip_rect,
    float scale_factor) {
  TRACE_EVENT0("paint_preview", "PaintPreviewCompositorImpl::CreateBitmap");
  const gfx::Rect clip_rect =
      AdjustClipRect(raw_clip_rect, skp->cullRect(), scale_factor);
  SkBitmap bitmap;
  if (!bitmap.tryAllocPixels(
          SkImageInfo::MakeN32Premul(clip_rect.width(), clip_rect.height()))) {
    return std::nullopt;
  }

  SkCanvas canvas(bitmap, skia::LegacyDisplayGlobals::GetSkSurfaceProps());
  SkMatrix matrix;
  matrix.setScaleTranslate(scale_factor, scale_factor, -clip_rect.x(),
                           -clip_rect.y());
  canvas.drawPicture(skp, &matrix, nullptr);
  return bitmap;
}
