#ifndef ARX_DOCUMENT_RECORDING_PEERS_H_
#define ARX_DOCUMENT_RECORDING_PEERS_H_
#include <cassert>
#include <limits>
#include <optional>
#include <tuple>
#include <type_traits>
#include <utility>
#include "document_resource_peers.h"
#include "arx_capture_recording_budget.h"
#define DCHECK_IS_ON() 0
#define CHECK(value) assert(value)
#define DCHECK_GE(left, right) assert((left) >= (right))
using SkPath = cc::Path;
template <typename T> using sk_sp = std::shared_ptr<T>;
namespace cc {
struct PaintOpBuffer {};
inline int retained_ops = 0, constructed_ops = 0;
struct AdmittedOp {
  static constexpr auto kType = PaintOpType::kDrawRect;
  template <typename... T> explicit AdmittedOp(T&&...) { ++constructed_ops; }
};
struct UnsupportedOp {
  static constexpr auto kType = PaintOpType::kSaveLayerFilters;
  explicit UnsupportedOp() { ++constructed_ops; }
};
struct SaveOp { static constexpr auto kType = PaintOpType::kSave; };
struct RestoreOp { static constexpr auto kType = PaintOpType::kRestore; };
class RecordPaintCanvas {
 public:
  template <typename T, typename... Args> void push(Args&&... args);
  int save();
  void restore();
  int save_count_ = 1;
  struct Buffer {
    template <typename T, typename... Args> void push(Args&&... args) {
      T operation{std::forward<Args>(args)...};
      (void)operation;
      ++retained_ops;
    }
  } buffer_;
};
}
namespace blink {
using wtf_size_t = size_t;
inline constexpr size_t kNotFound = std::numeric_limits<size_t>::max();
struct DisplayItemClient { int Id() const { return 1; } };
struct DisplayItem {
  virtual ~DisplayItem() = default;
  void SetFragment(int) {}
  struct Id { int value; };
  Id GetId() const { return {1}; }
  bool IsForeignLayer() const { return false; }
  bool IsScrollbar() const { return false; }
};
struct ScrollbarDisplayItem : DisplayItem {};
struct DrawingDisplayItem : DisplayItem { explicit DrawingDisplayItem(int) {} };
class ForeignLayerDisplayItem : public DisplayItem { public: explicit ForeignLayerDisplayItem(int) {} };
struct ItemList {
  template <typename T, typename... Args> T& AllocateAndConstruct(Args&&... args) {
    auto value = std::make_unique<T>(std::forward<Args>(args)...);
    auto* pointer = value.get();
    items.push_back(std::move(value));
    return *pointer;
  }
  std::vector<std::unique_ptr<DisplayItem>> items;
};
struct Artifact {
  ItemList list;
  ItemList& GetDisplayItemList() { return list; }
};
struct Properties { bool IsInitialized() const { return true; } };
struct PaintChunk {
  using Id = DisplayItem::Id;
  template <typename... Args> PaintChunk(int begin, int end, Args&&...) : end_index(end) { (void)begin; }
  int end_index;
};
struct ChunkerPeer { void SetWillForceNewChunk() {} };
struct SubsequenceMarkers { int client_id; size_t start_chunk_index; };
class PaintChunker {
 public:
  void CheckNotFinished() {}
  bool EnsureCurrentChunk(const PaintChunk::Id&, const DisplayItemClient&);
  bool IncrementDisplayItemIndex(const DisplayItemClient&, const DisplayItem&);
  bool WillCreateNewChunk() const { return will_force_new_chunk_ || chunks_.empty(); }
  void SetWillForceNewChunk() { will_force_new_chunk_ = true; next_chunk_id_.reset(); }
  void FinalizeLastChunkProperties() {}
  void MarkClientForValidation(const DisplayItemClient&) { ++marked; }
  int marked = 0;
  std::optional<std::pair<PaintChunk::Id, const DisplayItemClient&>> next_chunk_id_;
  std::vector<PaintChunk> chunks_;
  bool will_force_new_chunk_ = true;
  Properties current_properties_;
  bool current_effectively_invisible_ = false;
};
}
#endif
