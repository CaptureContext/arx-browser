"""Execute the embedder/fallback contract without launching a Chromium/PiP window."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.overlay import PACKAGE, apply_media_activation


class MediaActivationTests(unittest.TestCase):
    def test_owned_rejection_never_falls_back_to_native_focus(self):
        bridge = (PACKAGE / "Native/engine_bridge.mm").read_text()
        anchor = "base::BindRepeating([](content::WebContents* contents) {"
        start = bridge.index(anchor) + len(anchor)
        callback = bridge[start:bridge.index("\n              }));", start)]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manager = root / "chrome/browser/picture_in_picture"
            manager.mkdir(parents=True)
            (manager / "picture_in_picture_window_manager.h").write_text(
                '#include "base/memory/raw_ptr.h"\n'
                "  // Called to notify that the initiator web contents should be focused.\n"
                "  void FocusInitiator();\n private:\n"
            )
            implementation = manager / "picture_in_picture_window_manager.cc"
            implementation.write_text(
                "    case UiBehavior::kCloseWindowAndFocusOpener:\n"
                "      pip_window_controller_->CloseAndFocusInitiator();\n"
                "      break;\n"
                "void PictureInPictureWindowManager::FocusInitiator() {\n"
                "  if (pip_window_controller_)\n"
                "    pip_window_controller_->FocusInitiator();\n}\n"
            )
            apply_media_activation(root)
            close, focus = implementation.read_text().split(
                "void PictureInPictureWindowManager::FocusInitiator()", 1
            )
            source = root / "contract.cc"
            source.write_text(HARNESS.replace("CALLBACK_BODY", callback)
                              .replace("CLOSE_BODY", close)
                              .replace("FOCUS_BODY", focus))
            executable = root / "contract"
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                            str(source), "-o", str(executable)],
                           check=True, capture_output=True, timeout=30)
            subprocess.run([str(executable)], check=True, capture_output=True, timeout=5)


# Controller doubles count the fallback side effects. The hook body and both
# manager branches above come from production files; we do not copy their policy.
HARNESS = r"""
#include <cassert>
#include <functional>
#include <utility>
#include <vector>
namespace content { struct WebContents {}; }
struct Media {
  bool accept = true;
  int attempts = 0;
  bool Activate() { ++attempts; return accept; }
};
struct Page {
  content::WebContents* contents_;
  Media* media_;
  content::WebContents* contents() { return contents_; }
  Media* media() { return media_; }
};
struct Runtime {
  bool running = true;
  std::vector<std::pair<int, Page*>> pages;
};
Runtime& State() { static Runtime state; return state; }
struct Callback {
  std::function<bool(content::WebContents*)> function;
  operator bool() const { return bool(function); }
  bool Run(content::WebContents* contents) { return function(contents); }
};
struct Controller {
  content::WebContents* contents;
  int focused = 0, closed = 0;
  content::WebContents* GetWebContents() { return contents; }
  void FocusInitiator() { ++focused; }
  void Close(bool should_pause_video) { assert(!should_pause_video); ++closed; }
  void CloseAndFocusInitiator() { Close(false); FocusInitiator(); }
};
class PictureInPictureWindowManager {
 public:
  enum class UiBehavior { kCloseWindowAndFocusOpener };
  Controller* pip_window_controller_;
  Callback initiator_activation_callback_;
  void Close() {
    switch (UiBehavior::kCloseWindowAndFocusOpener) { CLOSE_BODY }
  }
  void FocusInitiator();
};
void PictureInPictureWindowManager::FocusInitiator() FOCUS_BODY
int main() {
  const auto hook = [](content::WebContents* contents) { CALLBACK_BODY };
  content::WebContents owned, other;
  Media media;
  Page page{&owned, &media};
  State().pages = {{1, &page}};
  for (bool accepted : {true, false}) {
    media.accept = accepted;
    media.attempts = 0;
    Controller controller{&owned};
    PictureInPictureWindowManager manager{&controller, Callback{hook}};
    manager.Close();
    manager.FocusInitiator();
    assert(media.attempts == 2);
    assert(controller.closed == 1 && controller.focused == 0);
  }
  for (bool hook_installed : {true, false}) {
    Controller controller{&other};
    PictureInPictureWindowManager manager{&controller, {}};
    if (hook_installed) manager.initiator_activation_callback_ = Callback{hook};
    manager.Close();
    manager.FocusInitiator();
    assert(controller.closed == 1 && controller.focused == 2);
  }
}
"""
