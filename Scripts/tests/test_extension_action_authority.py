"""Production native menu authority and source teardown interleavings."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE


class ExtensionActionAuthorityTests(unittest.TestCase):
    def test_one_use_source_bound_actions_and_reentrant_close(self):
        source = r'''#include "extension_action_policy.h"
#include "adoption_scope.h"
#include <cassert>
int main() {
  arx::ExtensionActionAuthority authority;
  assert(!authority.Issue(0));
  auto first = authority.Issue(1);
  auto second = authority.Issue(1);
  assert(first && second && first != second);
  assert(!authority.Consume(first+100,1,true,true));
  assert(authority.Consume(first,1,true,true));
  assert(!authority.Consume(first,1,true,true));
  assert(!authority.Consume(second,1,true,true)); // closes the whole menu
  for (int reason=0;reason<3;++reason) {
    auto token=authority.Issue(7);
    assert(token>second);
    assert(!authority.Consume(token,reason==0?8:7,reason!=1,reason!=2));
    assert(!authority.Consume(token,7,true,true));
  }
  auto stale=authority.Issue(8);
  authority.Clear();
  auto fresh=authority.Issue(8);
  assert(fresh>stale);
  assert(!authority.Consume(stale,8,true,true));
  assert(authority.Consume(fresh,8,true,true));
  for (unsigned i=0;i<512;++i) assert(authority.Issue(9));
  assert(!authority.Issue(9));
  assert(authority.Issue(10)); // new document releases the old menu's bound
  arx::ExtensionPopupEpoch popup;
  auto old_close=popup.ScheduleClose();
  assert(old_close && !popup.ScheduleClose());
  assert(popup.Advance()); // old popup closes
  assert(popup.Advance()); // a new popup is established
  assert(!popup.Current(old_close));
  auto new_close=popup.ScheduleClose();
  assert(new_close && new_close!=old_close && popup.Current(new_close));
  assert(popup.Advance());
  assert(!popup.Current(new_close));
  arx::ExtensionShortcutReplayGuard shortcut;
  assert(!shortcut.Consume(0, 10, 9, 10));
  assert(!shortcut.Consume(1, 8, 9, 10)); // queued before host replacement
  assert(!shortcut.Consume(1, 11, 9, 10)); // future native timestamp
  assert(!shortcut.Consume(1, 10, 9, 16)); // delayed beyond native admission
  assert(shortcut.Consume(1, 10, 9, 10));
  assert(!shortcut.Consume(1, 10, 9, 10));
  assert(!shortcut.Consume(2, 10, 9, 10)); // a reconstructed event cannot replay
  assert(!shortcut.Consume(3, 9.5, 9, 10)); // out-of-order stale native event
  assert(!shortcut.Consume(3, 11, 12, 12)); // rehosted source has a later epoch
  assert(shortcut.Consume(3, 12, 12, 12));
  assert(!shortcut.Consume(4, std::nan(""), 12, 12));
  assert(!shortcut.Consume(4, 13, 12, INFINITY));
  assert(shortcut.Consume(4, 13, 12, 13));
  arx::AdoptionScope physical;
  assert(!physical.DestroyRequested(12));
  assert(physical.Begin(12));
  assert(physical.Begin(12));
  assert(physical.DeferDestroy(12));
  assert(physical.DestroyRequested(12)); // decline popup after reentrant close
  assert(!physical.DestroyRequested(13));
  assert(!physical.End(12));
  assert(physical.DestroyRequested(12));
  assert(physical.End(12));
  assert(!physical.DestroyRequested(12));
}'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                "-fsanitize=address,undefined", "-I", str(PACKAGE / "Native"),
                str(root / "test.cc"), "-o", str(root / "test"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
