#ifndef THIRD_PARTY_BLINK_RENDERER_CORE_INPUT_ARX_KEYPRESS_GUARD_H_
#define THIRD_PARTY_BLINK_RENDERER_CORE_INPUT_ARX_KEYPRESS_GUARD_H_

#include "third_party/blink/renderer/core/core_export.h"

namespace blink {
class Event;

// Same-task authority for one explicit-reference key sequence. Author listeners
// run with default-action authority suspended; their own script side effects are
// not prevented. The pure callback binds the original control and selection.
class CORE_EXPORT ArxKeypressGuard final {
 public:
  using Check = bool (*)(void*);
  ArxKeypressGuard(Check, void*);
  ~ArxKeypressGuard();
  ArxKeypressGuard(const ArxKeypressGuard&) = delete;
  ArxKeypressGuard& operator=(const ArxKeypressGuard&) = delete;
  bool installed() const { return installed_; }
  bool suppressed() const { return suppressed_; }
  bool fallback_handled() const { return fallback_handled_; }
  void SetEvent(const Event* event) {
    event_ = event;
    fallback_handled_ = false;
  }
  static bool IsGuardedEvent(const Event*);
  static void MarkFallbackHandled(const Event*);
  static bool BeforeEdit();
  static bool BeforeDefault(const Event*);
  static bool Busy() { return current_ != nullptr; }

  class CORE_EXPORT AuthorDispatch final {
   public:
    AuthorDispatch();
    ~AuthorDispatch();
    AuthorDispatch(const AuthorDispatch&) = delete;
    AuthorDispatch& operator=(const AuthorDispatch&) = delete;
   private:
    ArxKeypressGuard* guard_;
    bool previous_;
  };
  class CORE_EXPORT DefaultAction final {
   public:
    explicit DefaultAction(const Event*);
    ~DefaultAction();
    DefaultAction(const DefaultAction&) = delete;
    DefaultAction& operator=(const DefaultAction&) = delete;
    bool allowed() const { return allowed_; }
   private:
    ArxKeypressGuard* guard_;
    bool previous_;
    bool allowed_;
    const Event* previous_event_;
  };
 private:
  bool Matches(const Event*) const;
  bool Current();
  static thread_local ArxKeypressGuard* current_;
  Check check_;
  void* context_;
  const Event* event_ = nullptr;
  const Event* default_event_ = nullptr;
  bool installed_ = false;
  bool in_default_ = false;
  bool suppressed_ = false;
  bool fallback_handled_ = false;
};
}  // namespace blink
#endif
