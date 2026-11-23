#include <cassert>
#include <string>
#include "close_authority.h"

int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string name = argv[1];
  arx::CloseAuthority page, other;
  const auto generation = page.generation();
  assert(page.Start(10, generation) == ARX_CLOSE_SUCCESS);
  if (name == "cancel-slot") {
    page.Cancel(10);
    assert(page.busy() && page.waiting());
    assert(page.Start(11, generation) == ARX_CLOSE_BUSY);
    assert(page.Decide(true, true, 100) == ARX_CLOSE_CANCELLED);
    assert(!page.busy());
    assert(page.Start(11, generation) == ARX_CLOSE_SUCCESS);
    assert(page.Decide(true, true, 101) == ARX_CLOSE_SUCCESS);
    assert(page.Consume(10, 100, true) == ARX_CLOSE_STALE);
    assert(page.Consume(11, 101, true) == ARX_CLOSE_SUCCESS);
  } else if (name == "reset-retry") {
    page.Cancel(10);
    page.Invalidate();
    assert(!page.Reset(9));
    assert(page.busy());
    assert(page.Reset(10));
    assert(page.Start(11, page.generation()) == ARX_CLOSE_SUCCESS);
    assert(!page.Reset(10));
    assert(page.request() == 11 && page.waiting());
    assert(page.Decide(true, true, 101) == ARX_CLOSE_SUCCESS);
    assert(page.Consume(11, 101, true) == ARX_CLOSE_SUCCESS);
  } else if (name == "navigation-pending") {
    page.Invalidate();
    assert(page.busy());
    assert(page.Decide(true, true, 100) == ARX_CLOSE_STALE);
    assert(page.Start(11, generation) == ARX_CLOSE_STALE);
    assert(page.Start(11, page.generation()) == ARX_CLOSE_SUCCESS);
  } else if (name == "navigation-approved") {
    assert(page.Decide(true, true, 100) == ARX_CLOSE_SUCCESS);
    assert(page.Valid(10, 100, true));
    page.Invalidate();
    assert(!page.Valid(10, 100, true));
    assert(page.Consume(10, 100, true) == ARX_CLOSE_STALE);
  } else if (name == "weak-document") {
    assert(page.Decide(true, false, 100) == ARX_CLOSE_STALE);
    assert(page.Start(11, generation) == ARX_CLOSE_SUCCESS);
    assert(page.Decide(true, true, 101) == ARX_CLOSE_SUCCESS);
    assert(page.Consume(11, 101, false) == ARX_CLOSE_STALE);
    assert(page.Consume(11, 101, true) == ARX_CLOSE_STALE);
  } else if (name == "replay-other-page") {
    assert(page.Decide(true, true, 100) == ARX_CLOSE_SUCCESS);
    assert(other.Start(10, other.generation()) == ARX_CLOSE_SUCCESS);
    assert(other.Decide(true, true, 101) == ARX_CLOSE_SUCCESS);
    assert(other.Consume(10, 100, true) == ARX_CLOSE_STALE);
    assert(page.Consume(11, 100, true) == ARX_CLOSE_STALE);
    assert(page.Consume(10, 0, true) == ARX_CLOSE_STALE);
    assert(page.Consume(10, 100, true) == ARX_CLOSE_SUCCESS);
    assert(page.Consume(10, 100, true) == ARX_CLOSE_STALE);
    assert(other.Consume(10, 101, true) == ARX_CLOSE_SUCCESS);
  } else if (name == "refused-cancel-approved") {
    assert(page.Decide(false, true, 100) == ARX_CLOSE_REFUSED);
    assert(page.Start(11, generation) == ARX_CLOSE_SUCCESS);
    assert(page.Decide(true, true, 101) == ARX_CLOSE_SUCCESS);
    page.Cancel(12);
    assert(page.Valid(11, 101, true));
    page.Cancel(11);
    assert(page.Consume(11, 101, true) == ARX_CLOSE_STALE);
  } else if (name == "invalid") {
    page.Cancel(10);
    page.Decide(true, true, 100);
    assert(page.Start(0, generation) == ARX_CLOSE_STALE);
    assert(page.Start(1, 0) == ARX_CLOSE_STALE);
    assert(page.Start(1, generation) == ARX_CLOSE_SUCCESS);
    assert(page.Decide(true, true, 0) == ARX_CLOSE_UNAVAILABLE);
  } else { assert(false); }
}
