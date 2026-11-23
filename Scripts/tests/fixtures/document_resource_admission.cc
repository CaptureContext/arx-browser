#include <cassert>
#include <climits>
#include <memory>

#include "components/paint_preview/arx/record_admission.h"
#include "cc/paint/paint_op.h"

using namespace arx::document;
using Status = mojom::Status;
Status Inspect(const cc::PaintRecord& record, mojom::Limits limits = {}) {
  base::TimeTicks::now = 0;
  RecordAdmission admission(limits, base::TimeTicks(100));
  return admission.Inspect(record);
}
int main() {
  cc::DrawImageOp image;
  cc::PaintRecord record;
  record.ops = {&image};
  assert(Inspect(record) == Status::kSuccess);  // exact 256-byte decoded budget
  image.image.width = INT_MAX;
  assert(Inspect(record) == Status::kLimit);    // no readback API exists on peer
  image.image.width = 8;
  record.ops.push_back(&image);
  assert(Inspect(record) == Status::kLimit);   // repeated resources charged per use
  image.image.bytes = 1; image.image.color = kAlpha_8_SkColorType;
  assert(Inspect(record) == Status::kLimit); // utility N32 decode, not source A8 size
  image.image.bytes = 4; image.image.color = kN32_SkColorType;
  record.ops.pop_back();
  for (bool cc::PaintImage::* member : {&cc::PaintImage::lazy, &cc::PaintImage::deferred,
                                      &cc::PaintImage::animated, &cc::PaintImage::gainmap}) {
    image.image.*member = true;
    assert(Inspect(record) == Status::kUnsupported);
    image.image.*member = false;
  }
  image.image.color = kUnknown_SkColorType;
  assert(Inspect(record) == Status::kUnsupported);
  image.image.color = kN32_SkColorType;
  for (bool cc::PaintFlags::* member : {&cc::PaintFlags::shader, &cc::PaintFlags::filter,
                                      &cc::PaintFlags::path, &cc::PaintFlags::color, &cc::PaintFlags::looper}) {
    image.flags.*member = true;
    assert(Inspect(record) == Status::kUnsupported);
    image.flags.*member = false;
  }
  // Solid and linear-gradient shaders (classic scrollbar tracks) are admitted;
  // other gradients, image and record shaders are not.
  image.flags.shader = true;
  for (auto type : {cc::PaintShader::Type::kColor, cc::PaintShader::Type::kLinearGradient}) {
    image.flags.shader_value.type = type;
    assert(Inspect(record) != Status::kUnsupported);
  }
  for (auto type : {cc::PaintShader::Type::kRadialGradient, cc::PaintShader::Type::kImage,
                    cc::PaintShader::Type::kPaintRecord}) {
    image.flags.shader_value.type = type;
    assert(Inspect(record) == Status::kUnsupported);
  }
  image.flags.shader = false;
  image.flags.shader_value.type = cc::PaintShader::Type::kImage;
  for (auto type : {cc::PaintOpType::kSaveLayer, cc::PaintOpType::kSaveLayerFilters,
                   cc::PaintOpType::kDrawSkottie, cc::PaintOpType::kCustomData,
                   cc::PaintOpType::kDrawVertices, cc::PaintOpType::kDrawScrollingContents}) {
    cc::PaintOp unsupported(type);
    record.ops = {&unsupported};
    assert(Inspect(record) == Status::kUnsupported);
  }
  cc::DrawTextBlobOp text;
  text.blob = std::make_shared<SkTextBlob>();
  text.blob->glyphs = {50, 50}; record.ops = {&text};
  assert(Inspect(record) == Status::kSuccess);
  text.blob->glyphs = {50, 51};
  assert(Inspect(record) == Status::kLimit);
  text.blob->glyphs = {1};
  text.blob->typeface.tables = 257;
  assert(Inspect(record) == Status::kLimit);
  text.blob->typeface.tables = 1;
  text.blob->typeface.table_size = 1024;
  assert(Inspect(record) == Status::kLimit);  // table + directory exceed budget
  cc::DrawPathOp path;
  path.path.bytes = 1024; record.ops = {&path};
  assert(Inspect(record) == Status::kSuccess);
  record.ops.push_back(&path);
  assert(Inspect(record) == Status::kLimit);
  cc::PaintOp save(cc::PaintOpType::kSave), restore(cc::PaintOpType::kRestore);
  record.ops.assign(65, &save);
  assert(Inspect(record) == Status::kLimit);
  record.ops = {&restore};
  assert(Inspect(record) == Status::kUnsupported);
  cc::SaveLayerAlphaOp alpha;
  for (float value : {0.f, 0.5f, 1.f}) {
    alpha.alpha = value;
    record.ops = {&alpha, &restore};
    assert(Inspect(record) == Status::kSuccess);
  }
  for (float value : {-1.f, 1.1f, __builtin_inff(), __builtin_nanf("")}) {
    alpha.alpha = value;
    assert(Inspect(record) == Status::kUnsupported);
  }
  alpha.alpha = 1.f; alpha.valid = false;
  assert(Inspect(record) == Status::kUnsupported);
  alpha.valid = true;
  record.ops.assign(65, &alpha);
  assert(Inspect(record) == Status::kLimit);
  record.ops = {&alpha};
  assert(Inspect(record) == Status::kUnsupported);  // unbalanced isolation
  cc::DrawRecordOp nested[33];
  for (int i = 0; i < 32; ++i) nested[i].record.ops = {&nested[i + 1]};
  record.ops = {&nested[0]};
  assert(Inspect(record) == Status::kLimit);
  record.ops = {&image};
  RecordAdmission conversion({}, base::TimeTicks(100));
  assert(conversion.Inspect(record) == Status::kSuccess);
  base::TimeTicks::now = 100;
  assert(!conversion.Continue(image));
  assert(conversion.status() == Status::kTimeout);
  base::TimeTicks::now = 0;
  assert(!conversion.Continue(image));  // failure cannot become a partial success
}
