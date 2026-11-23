namespace blink {
thread_local ArxKeypressGuard* ArxKeypressGuard::current_ = nullptr;
ArxKeypressGuard::ArxKeypressGuard(Check check, void* context)
    : check_(check), context_(context) {
  if (check_ && !current_) {
    installed_ = true;
    current_ = this;
  }
}
ArxKeypressGuard::~ArxKeypressGuard() {
  if (installed_) current_ = nullptr;
}
bool ArxKeypressGuard::Matches(const Event* event) const {
  // Native textInput has the originating KeyboardEvent as its underlying event.
  // Do not attach authority to unrelated events or an unbounded author chain.
  for (unsigned depth = 0; event && depth < 16; ++depth) {
    if (event == event_) return true;
    event = event->UnderlyingEvent();
  }
  return false;
}
bool ArxKeypressGuard::Current() {
  if (suppressed_ || !check_(context_)) {
    suppressed_ = true;
    return false;
  }
  return true;
}
bool ArxKeypressGuard::IsGuardedEvent(const Event* event) {
  return current_ && current_->Matches(event);
}
void ArxKeypressGuard::MarkFallbackHandled(const Event* event) {
  // Only the exact keyboard event's allowed native default may authorize the
  // character continuation. A nested textInput's underlying match is not proof.
  if (current_ && current_->in_default_ && current_->event_ == event &&
      current_->default_event_ == event && current_->Current()) {
    current_->fallback_handled_ = true;
  }
}
bool ArxKeypressGuard::BeforeDefault(const Event* event) {
  return !current_ || !current_->Matches(event) || current_->Current();
}
bool ArxKeypressGuard::BeforeEdit() {
  return !current_ || !current_->in_default_ || current_->Current();
}
ArxKeypressGuard::AuthorDispatch::AuthorDispatch()
    : guard_(current_), previous_(guard_ && guard_->in_default_) {
  if (guard_) guard_->in_default_ = false;
}
ArxKeypressGuard::AuthorDispatch::~AuthorDispatch() {
  if (guard_) guard_->in_default_ = previous_;
}
ArxKeypressGuard::DefaultAction::DefaultAction(const Event* event)
    : guard_(current_), previous_(guard_ && guard_->in_default_), allowed_(true),
      previous_event_(guard_ ? guard_->default_event_ : nullptr) {
  if (guard_) guard_->default_event_ = event;
  if (guard_ && guard_->Matches(event)) {
    allowed_ = guard_->Current();
    guard_->in_default_ = allowed_;
  }
}
ArxKeypressGuard::DefaultAction::~DefaultAction() {
  if (guard_) {
    guard_->in_default_ = previous_;
    guard_->default_event_ = previous_event_;
  }
}
}  // namespace blink
