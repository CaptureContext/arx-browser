"""webRequest routing for several private windows of one profile (DEV-889)."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine import private_extension_routing_overlay as overlay

# ARX_PINNED_ENGINE_SOURCE names a prepared, unpatched tree (read only).
PINNED = Path(os.environ.get("ARX_PINNED_ENGINE_SOURCE", "/nonexistent"))

# Chromium's CrossContextData and the start of OnOTRBrowserContextDestroyed, as pinned.
UPSTREAM = '''class CrossContextData {
 public:
  CrossContextData() = default;
  ~CrossContextData() = default;
  CrossContextData(const CrossContextData&) = delete;
  CrossContextData& operator=(const CrossContextData&) = delete;

  static CrossContextData& Get() {
    static base::NoDestructor<CrossContextData> instance;
    return *instance.get();
  }

  content::BrowserContext* GetCrossBrowserContext(
      content::BrowserContext* browser_context) {
    const auto it = cross_context_data_.find(browser_context);
    return it == cross_context_data_.end() ? nullptr : it->second;
  }

  void AddContext(content::BrowserContext* original_browser_context,
                  content::BrowserContext* otr_browser_context) {
    cross_context_data_[original_browser_context] = otr_browser_context;
    cross_context_data_[otr_browser_context] = original_browser_context;
  }

''' + overlay.REMOVE + '''
 private:
  using CrossContextMap =
      std::map<content::BrowserContext*,
               raw_ptr<content::BrowserContext, CtnExperimental>>;

  CrossContextMap cross_context_data_;
};

void ClearCrossContextData(content::BrowserContext* browser_context) {
  CrossContextData::Get().RemoveContext(browser_context);
}

void OnOTRBrowserContextDestroyed(
    content::BrowserContext* original_browser_context,
''' + overlay.DESTROYED + '''}
'''

# Stand-ins for the few Chromium types the class uses.
PRELUDE = '''#include <cassert>
#include <map>
namespace content {
struct BrowserContext {
  bool off_the_record = false;
  bool IsOffTheRecord() const { return off_the_record; }
};
}  // namespace content
struct CtnExperimental {};
template <typename T, typename Traits = void>
struct raw_ptr {
  T* value = nullptr;
  raw_ptr() = default;
  raw_ptr(T* pointer) : value(pointer) {}
  operator T*() const { return value; }
};
namespace base {
template <typename T> struct NoDestructor {
  T value;
  T* get() { return &value; }
};
}  // namespace base
'''

SCENARIO = '''
int main() {
  auto& data = CrossContextData::Get();
  content::BrowserContext profile, first{true}, second{true}, other_profile, other_child{true};
  data.AddContext(&profile, &first);
  data.AddContext(&profile, &second);
  data.AddContext(&other_profile, &other_child);
  // Both windows' requests reach the profile's extensions.
  assert(data.GetCrossBrowserContext(&first) == &profile);
  assert(data.GetCrossBrowserContext(&second) == &profile);
  assert(data.GetCrossBrowserContext(&profile) == &second);

  // Closing the newer window keeps the older one's, and the profile pairs with it.
  OnOTRBrowserContextDestroyed(&profile, &second);
  assert(data.GetCrossBrowserContext(&second) == nullptr);
  assert(data.GetCrossBrowserContext(&first) == &profile);
  assert(data.GetCrossBrowserContext(&profile) == &first);

  // A window opened again, then the older one closed: the newer one stays paired.
  data.AddContext(&profile, &second);
  OnOTRBrowserContextDestroyed(&profile, &first);
  assert(data.GetCrossBrowserContext(&second) == &profile);
  assert(data.GetCrossBrowserContext(&profile) == &second);

  // The last window closed: the profile has no partner.
  OnOTRBrowserContextDestroyed(&profile, &second);
  assert(data.GetCrossBrowserContext(&profile) == nullptr);

  // Another profile's pairing is never touched; removing a profile removes its children.
  assert(data.GetCrossBrowserContext(&other_child) == &other_profile);
  data.AddContext(&profile, &first);
  ClearCrossContextData(&profile);
  assert(data.GetCrossBrowserContext(&first) == nullptr);
  assert(data.GetCrossBrowserContext(&profile) == nullptr);
  assert(data.GetCrossBrowserContext(&other_profile) == &other_child);
  return 0;
}
'''


class PrivateExtensionRoutingOverlayTests(unittest.TestCase):
    def apply(self, root):
        path = root / overlay.SOURCE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(UPSTREAM)
        overlay.apply(root)
        return path

    def test_applies_once(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.apply(Path(directory))
            first = path.read_text()
            overlay.apply(Path(directory))
            self.assertEqual(first, path.read_text())
            self.assertIn("ClearCrossContextData(otr_browser_context);", first)
            self.assertNotIn("ClearCrossContextData(original_browser_context);", first)

    def test_closing_one_private_window_keeps_the_others_routing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patched = self.apply(root).read_text()
            source = root / "routing.cc"
            source.write_text(PRELUDE + patched + SCENARIO)
            executable = root / "routing"
            result = subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                 "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                 str(source), "-o", str(executable)],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_changed_anchor_stops_the_build(self):
        for index, (relative, anchor, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(UPSTREAM.replace(anchor, "changed upstream\n"))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(Path(directory))

    def test_anchors_match_the_pinned_source(self):
        if not PINNED.is_dir():
            self.skipTest("the pinned engine source isn't on this Mac")
        for relative, anchor, replacement in overlay.patches():
            with self.subTest(anchor=anchor.splitlines()[0]):
                text = (PINNED / relative).read_text()
                self.assertEqual(text.count(anchor) + text.count(replacement), 1)


if __name__ == "__main__":
    unittest.main()
