#ifndef ARX_EXTERNAL_HANDOFF_AUTHORITY_H_
#define ARX_EXTERNAL_HANDOFF_AUTHORITY_H_

#include <cstdint>

namespace arx {
// One retained child may perform exactly its original primary navigation.
// Finishing is irreversible; late shell/dialog callbacks cannot revive it.
class ExternalHandoffAuthority {
 public:
  bool live() const { return state_ != State::kFinished; }
  bool deciding() const { return state_ == State::kNavigation || state_ == State::kProtocol; }
  bool BeginNavigation(int64_t id, bool primary, bool same_document, bool exact_target) {
    if (state_ != State::kAwaitResume || !id || !primary || same_document || !exact_target) {
      Finish();
      return false;
    }
    navigation_ = id;
    state_ = State::kNavigation;
    return true;
  }
  bool ProtocolStarted() {
    if (!deciding()) return false;
    state_ = State::kProtocol;
    return true;
  }
  bool NavigationFinished(int64_t id, bool committed) {
    if (!live()) return true;
    if (id != navigation_ || committed || state_ != State::kProtocol) {
      Finish();
      return true;
    }
    // ERR_ABORTED is normal while Chrome owns the external prompt/worker.
    return false;
  }
  bool Finish() {
    if (!live()) return false;
    state_ = State::kFinished;
    return true;
  }
 private:
  enum class State { kAwaitResume, kNavigation, kProtocol, kFinished };
  State state_ = State::kAwaitResume;
  int64_t navigation_ = 0;
};
}  // namespace arx
#endif
