"""Run the exact scoped default-action guard with deterministic author peers."""

from pathlib import Path
import json
import subprocess
import tempfile
import unittest

from Scripts.engine.config import PACKAGE
from Scripts.engine import inspection_overlay, keypress_actions_overlay
from Scripts.engine.overlay import replace_once


class KeypressGuardTests(unittest.TestCase):
    def test_author_side_effects_do_not_get_default_authority_and_suppression_latches(self):
        header = (PACKAGE / "Native/inspection/keypress_guard_contract.h").read_text()
        header = header.replace('#include "third_party/blink/renderer/core/core_export.h"', '#define CORE_EXPORT')
        implementation = (PACKAGE / "Native/inspection/keypress_guard_impl.inc").read_text()
        peers = '''
#include <cassert>
namespace blink {
class Event {
 public:
  explicit Event(const Event* underlying = nullptr) : underlying_(underlying) {}
  const Event* UnderlyingEvent() const { return underlying_; }
 private: const Event* underlying_;
};
}
'''
        source = peers + header + implementation + '''
int main() {
  using namespace blink;
  bool current = true;
  const auto check = [](void* pointer) { return *static_cast<bool*>(pointer); };
  assert(ArxKeypressGuard::BeforeEdit());
  Event key, text(&key), unrelated;
  {
    ArxKeypressGuard guard(check, &current);
    assert(guard.installed() && ArxKeypressGuard::Busy());
    guard.SetEvent(&key);
    assert(ArxKeypressGuard::IsGuardedEvent(&key));
    assert(ArxKeypressGuard::IsGuardedEvent(&text));
    assert(!ArxKeypressGuard::IsGuardedEvent(&unrelated));
    ArxKeypressGuard nested(check, &current);
    assert(!nested.installed());
    {
      ArxKeypressGuard::AuthorDispatch author;
      current = false;  // author script may change focus/selection or edit itself
      assert(ArxKeypressGuard::BeforeEdit());
      current = true;
      {
        ArxKeypressGuard::DefaultAction native(&key);
        assert(native.allowed() && ArxKeypressGuard::BeforeEdit());
        {
          ArxKeypressGuard::AuthorDispatch beforeinput;
          current = false;
          assert(ArxKeypressGuard::BeforeEdit());  // don't block author's own script
          {
            ArxKeypressGuard::DefaultAction other(&unrelated);
            assert(other.allowed() && ArxKeypressGuard::BeforeEdit());
          }
        }
        assert(!ArxKeypressGuard::BeforeEdit());  // suppress redirected UA edit
        current = true;
        assert(!ArxKeypressGuard::BeforeEdit());  // cannot regain a failed receipt
      }
    }
    assert(guard.suppressed());
    ArxKeypressGuard::DefaultAction late(&text);
    assert(!late.allowed());
  }
  assert(!ArxKeypressGuard::Busy() && ArxKeypressGuard::BeforeEdit());
  {
    ArxKeypressGuard guard(check, &current);
    guard.SetEvent(&key);
    ArxKeypressGuard::AuthorDispatch author;
    ArxKeypressGuard::DefaultAction native(&key);
    assert(native.allowed());
  }
}
'''
        with tempfile.TemporaryDirectory(prefix="arx-keypress-guard-") as directory:
            root = Path(directory)
            (root / "guard.cc").write_text(source)
            compiled = subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                                       "-fsanitize=address,undefined", str(root / "guard.cc"),
                                       "-o", str(root / "guard")], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(root / "guard")], capture_output=True, text=True, timeout=5)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)

    def test_exact_production_key_parser_rejects_controls_sequences_and_surrogates(self):
        helper = (PACKAGE / "Native/inspection/keypress_action_helper.inc").read_text()
        parser = helper.split("ArxFormBaselineStatus CaptureKeypressBaseline", 1)[0]
        names = ("BACKSPACE", "DEL", "ARROW_LEFT", "ARROW_RIGHT", "ARROW_UP", "ARROW_DOWN", "HOME", "END", "ENTER")
        codes = ("BACK", "DELETE", "LEFT", "RIGHT", "UP", "DOWN", "HOME", "END", "RETURN")
        peers = r'''#include <cassert>
#include <cstdint>
#include <string>
using UChar = char16_t;
struct String : std::u16string {
 using std::u16string::u16string;
 bool operator!=(const char* other) const {
  std::u16string widened;
  while (*other) widened += static_cast<char16_t>(*other++);
  return static_cast<const std::u16string&>(*this) != widened;
 }
};
namespace ui {
struct DomKey {
 static int FromCharacter(uint32_t scalar) { return static_cast<int>(scalar); }
''' + "".join(f" static constexpr int {name} = {index + 1};\n" for index, name in enumerate(names)) + "};\n"
        peers += "".join(f"constexpr int VKEY_{name} = {index + 1};\n" for index, name in enumerate(codes)) + "}\n"
        source = peers + parser + r'''
int main() {
 for (const auto* text : {u"x", u"é", u" ", u"\U0001f642", u"Enter", u"Backspace", u"Delete", u"Home", u"End", u"ArrowLeft", u"ArrowRight", u"ArrowUp", u"ArrowDown"}) {
  ArxKeyDefinition key;
  assert(ArxDefineKey(String(text), &key));
 }
 for (const auto* text : {u"", u"ab", u"e\u0301", u"Tab", u"Escape", u"Control+a", u"\n", u"\r", u"\u007f", u"\u2028", u"\u2029", u"\uffff", u"\U0010ffff"}) {
  ArxKeyDefinition key;
  assert(!ArxDefineKey(String(text), &key));
 }
 for (const UChar value : {UChar(0xd800), UChar(0xdc00)}) {
  ArxKeyDefinition key;
  assert(!ArxDefineKey(String(1, value), &key));
 }
 ArxKeyDefinition key;
 assert(!ArxDefineKey(String(2, UChar(0xd800)), &key));
 assert(ArxDefineKey(String(u"\U0001f642"), &key));
 assert(key.character && key.text[0] == 0xd83d && key.text[1] == 0xde42 && !key.text[2]);
}
'''
        with tempfile.TemporaryDirectory(prefix="arx-keypress-parser-") as directory:
            root = Path(directory)
            (root / "parser.cc").write_text(source)
            result = subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                                     "-fsanitize=address,undefined", str(root / "parser.cc"),
                                     "-o", str(root / "parser")], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "parser")], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_guarded_refusal_cannot_reach_page_or_focus_default_fallback(self):
        bodies = [new for relative, old, new in keypress_actions_overlay.patches()
                  if relative.endswith("keyboard_event_manager.cc") and "SetDefaultHandled" in new]
        self.assertEqual(len(bodies), 2)
        # Execute the exact inserted branch with an editor refusing after a
        # hostile callback, and with an ordinary untagged keyboard event.
        branch = bodies[0].split("    // Do not perform", 1)[0]
        branch = branch[branch.index("    if (ArxKeypressGuard::IsGuardedEvent"):]
        source = r'''#include <cassert>
struct Event { bool handled = false; void SetDefaultHandled() { handled = true; } };
struct ArxKeypressGuard {
 static bool tagged;
 static bool IsGuardedEvent(Event*) { return tagged; }
 static void MarkFallbackHandled(Event*) {}
};
bool ArxKeypressGuard::tagged = false;
void DispatchAfterEditorRefusal(Event* event, bool& page_scroll, bool& focus_navigation) {
''' + branch + r'''
 page_scroll = true; focus_navigation = true;
}
int main() {
 Event event; bool scroll = false, focus = false;
 ArxKeypressGuard::tagged = true;
 DispatchAfterEditorRefusal(&event, scroll, focus);
 assert(event.handled && !scroll && !focus);
 event.handled = false; ArxKeypressGuard::tagged = false;
 DispatchAfterEditorRefusal(&event, scroll, focus);
 assert(!event.handled && scroll && focus);
}
'''
        with tempfile.TemporaryDirectory(prefix="arx-keypress-fallback-") as directory:
            root = Path(directory)
            (root / "fallback.cc").write_text(source)
            result = subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                                     "-fsanitize=address,undefined", str(root / "fallback.cc"),
                                     "-o", str(root / "fallback")], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "fallback")], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_actual_guard_fallback_and_helper_continue_only_exact_allowed_native_defaults(self):
        header = (PACKAGE / "Native/inspection/keypress_guard_contract.h").read_text()
        header = header.replace('#include "third_party/blink/renderer/core/core_export.h"', '#define CORE_EXPORT')
        implementation = (PACKAGE / "Native/inspection/keypress_guard_impl.inc").read_text()
        helper = (PACKAGE / "Native/inspection/keypress_action_helper.inc").read_text()
        continuation = helper[helper.index("  const auto down = dispatch("):]
        blocks = [new for relative, _, new in keypress_actions_overlay.patches()
                  if relative.endswith("keyboard_event_manager.cc") and "SetDefaultHandled" in new]
        branch = blocks[0].split("    // Do not perform", 1)[0]
        branch = branch[branch.index("    if (ArxKeypressGuard::IsGuardedEvent"):]
        source = (Path(__file__).parent / "fixtures/keypress_continuation.cc").read_text()
        source = source.replace("// GUARD_HEADER", header).replace("// GUARD_IMPL", implementation)
        source = source.replace("// NATIVE_FALLBACK", branch).replace("// HELPER_CONTINUATION", continuation)
        with tempfile.TemporaryDirectory(prefix="arx-keypress-continuation-") as directory:
            root = Path(directory)
            (root / "continuation.cc").write_text(source)
            result = subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                                     "-fsanitize=address,undefined", str(root / "continuation.cc"),
                                     "-o", str(root / "continuation")], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "continuation")], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_installed_previous_overlay_upgrades_without_duplicate_helpers_or_fallbacks(self):
        previous = json.loads((Path(__file__).parent / "fixtures/keypress_overlay_previous.json").read_text())
        self.assertEqual(previous["arx_revision"], "00c364d")
        with tempfile.TemporaryDirectory(prefix="arx-keypress-upgrade-") as directory:
            root = Path(directory)
            for relative, old, _ in inspection_overlay.patches():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            # Install the captured exact old source blocks, not a freshly rebuilt
            # overlay or a reversal of the new implementation.
            for block in previous["blocks"]:
                path = root / block["relative"]
                contents = path.read_text()
                self.assertEqual(contents.count(block["upstream_anchor"]), 1)
                path.write_text(contents.replace(block["upstream_anchor"], block["installed"], 1))
            inspection_overlay.apply(root)
            first = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            inspection_overlay.apply(root)
            self.assertEqual(first, {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()})
            helper = (root / "third_party/blink/renderer/core/exported/web_form_control_element.cc").read_text()
            keyboard = (root / "third_party/blink/renderer/core/input/keyboard_event_manager.cc").read_text()
            self.assertEqual(helper.count("ArxKeypressResult PerformKeypressForArxInspection("), 1)
            self.assertEqual(helper.count("const bool character_continuation ="), 1)
            self.assertEqual(keyboard.count("ArxKeypressGuard::MarkFallbackHandled(event);"), 2)

    def test_unknown_installed_helper_is_refused_before_nested_anchor_insertion(self):
        previous = json.loads((Path(__file__).parent / "fixtures/keypress_overlay_previous.json").read_text())
        with tempfile.TemporaryDirectory(prefix="arx-keypress-upgrade-refusal-") as directory:
            root = Path(directory)
            for block in previous["blocks"]:
                path = root / block["relative"]
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(block["installed"].replace("down == DispatchEventResult::kNotCanceled", "unexpected_dispatch") + "\n")
            with self.assertRaisesRegex(ValueError, "installed keypress block"):
                keypress_actions_overlay.upgrade_previous(root)
            helper = (root / "third_party/blink/renderer/core/exported/web_form_control_element.cc").read_text()
            self.assertEqual(helper.count("ArxKeypressResult PerformKeypressForArxInspection("), 1)

    def test_partial_known_installation_can_finish_without_duplicating_nested_anchors(self):
        blocks = json.loads((Path(__file__).parent / "fixtures/keypress_overlay_previous.json").read_text())["blocks"]
        current = {(relative, old): new for relative, old, new in keypress_actions_overlay.patches()}
        for installed_count in range(len(blocks)):
            with self.subTest(installed_count=installed_count), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for index, block in enumerate(blocks):
                    path = root / block["relative"]
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with path.open("a") as stream:
                        stream.write((block["installed"] if index < installed_count else block["upstream_anchor"]) + "\n")
                keypress_actions_overlay.upgrade_previous(root)
                for block in blocks:
                    path = root / block["relative"]
                    replace_once(path, block["upstream_anchor"], current[block["relative"], block["upstream_anchor"]])
                keypress_actions_overlay.upgrade_previous(root)
                for block in blocks:
                    contents = (root / block["relative"]).read_text()
                    self.assertEqual(contents.count(current[block["relative"], block["upstream_anchor"]]), 1)

    def test_overlay_guard_locations_and_no_activation_or_focus_synthesis(self):
        patches = keypress_actions_overlay.patches()
        text = "\n".join(new for _, _, new in patches)
        for forbidden in ("NotifyUserActivation", "SetFocusedElement", "HandleAccessKey", "EvaluateScript"):
            self.assertNotIn(forbidden, text)
        for marker in ("ArxKeypressGuard::AuthorDispatch", "ArxKeypressGuard::DefaultAction",
                       "ABORT_EDITING_COMMAND_IF(!ArxKeypressGuard::BeforeEdit())",
                       "if (!ArxKeypressGuard::BeforeEdit()) return true;",
                       "if (!ArxKeypressGuard::BeforeEdit()) return false;"):
            self.assertIn(marker, text)
