// Original pinned upstream admission seams, exercised with deterministic peers.
// Unchanged rendering/compositor behavior is deliberately outside this harness.
namespace cc {
// OP_ADMISSION
template <typename T, typename... Args>
void RecordPaintCanvas::push(Args&&... args) {
#if DCHECK_IS_ON()
  // The following check fails if client code does not check and handle
  // NeedsFlush() before issuing draw calls.
  // Note: restore ops are tolerated when flushes are requested since they are
  // often necessary in order to bring the canvas to a flushable state.
  // SetNodeId ops are also tolerated because they may be inserted just before
  // flushing.
  DCHECK(disable_flush_check_scope_ || !needs_flush_ ||
         (std::is_same<T, RestoreOp>::value) ||
         (std::is_same<T, SetNodeIdOp>::value));
#endif
  buffer_.push<T>(std::forward<Args>(args)...);
}
int RecordPaintCanvas::save() {
  push<SaveOp>();
  return save_count_++;
}
void RecordPaintCanvas::restore() {
  push<RestoreOp>();
  --save_count_;
  DCHECK_GE(save_count_, 1);
}
}
namespace blink {
class PaintController {
 public:
  template <typename DisplayItemClass, typename... Args>
  void CreateAndAppend(const DisplayItemClient& client, Args&&... args) {
    MarkClientForValidation(client);
    DisplayItemClass& display_item =
        new_paint_artifact_->GetDisplayItemList()
            .AllocateAndConstruct<DisplayItemClass>(
                client.Id(), std::forward<Args>(args)...);
    display_item.SetFragment(current_fragment_);
    ProcessNewItem(client, display_item);
  }
  void MarkClientForValidation(const DisplayItemClient&) { ++marked; }
  void ProcessNewItem(const DisplayItemClient&, DisplayItem&) { ++processed; }
  void RecordDebugInfo(const DisplayItemClient&) {}
  size_t NumNewChunks() const { return 0; }
  wtf_size_t BeginSubsequence(const DisplayItemClient& client);
  void EndSubsequence(wtf_size_t subsequence_index);
  int marked = 0, processed = 0;
  Artifact artifact;
  Artifact* new_paint_artifact_ = &artifact;
  int current_fragment_ = 0;
  ChunkerPeer paint_chunker_;
  struct { std::vector<SubsequenceMarkers> tree; } new_subsequences_;
};
bool PaintChunker::EnsureCurrentChunk(const PaintChunk::Id& id,
                                      const DisplayItemClient& client) {
#if DCHECK_IS_ON()
  CheckNotFinished();
#endif
  // If this CHECK is hit we are missing a call to update the properties.
  // See: ScopedPaintChunkProperties.
  // At this point we should have all of the properties given to us.
  CHECK(current_properties_.IsInitialized());

  if (WillCreateNewChunk()) {
    if (!next_chunk_id_) {
      next_chunk_id_.emplace(id, client);
    }
    FinalizeLastChunkProperties();
    wtf_size_t begin = chunks_.empty() ? 0 : chunks_.back().end_index;
    MarkClientForValidation(next_chunk_id_->second);
    chunks_.emplace_back(begin, begin, next_chunk_id_->second,
                         next_chunk_id_->first, current_properties_,
                         current_effectively_invisible_);
    next_chunk_id_ = std::nullopt;
    will_force_new_chunk_ = false;
    return true;
  }
  return false;
}
bool PaintChunker::IncrementDisplayItemIndex(const DisplayItemClient& client,
                                             const DisplayItem& item) {
  CheckNotFinished();
  bool item_forces_new_chunk = item.IsForeignLayer() || item.IsScrollbar();
  if (item_forces_new_chunk) {
    SetWillForceNewChunk();
  }
  bool created_new_chunk = EnsureCurrentChunk(item.GetId(), client);
  auto& chunk = chunks_.back();
  chunk.end_index++;

  return created_new_chunk;
}

wtf_size_t PaintController::BeginSubsequence(const DisplayItemClient& client) {
  RecordDebugInfo(client);
  // Force new paint chunk which is required for subsequence caching.
  paint_chunker_.SetWillForceNewChunk();
  new_subsequences_.tree.push_back(
      SubsequenceMarkers{client.Id(), NumNewChunks()});
  return new_subsequences_.tree.size() - 1;
}
void PaintController::EndSubsequence(wtf_size_t subsequence_index) {
  assert(subsequence_index < new_subsequences_.tree.size());
}

}
