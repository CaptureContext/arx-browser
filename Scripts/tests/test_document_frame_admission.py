"""Run the actual browser entry/current/continuation branches against frame peers."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine import document_capture_prototype as prototype


class DocumentFrameAdmissionTests(unittest.TestCase):
    def test_existing_child_is_unsupported_but_added_child_is_changed(self):
        source = (prototype.PROTOTYPE / "document_capture.cc").read_text()
        start = source.index("base::UnguessableToken CaptureDocumentPrototypeForTesting(")
        end = source.index("  Active() = std::make_unique<Operation>", start)
        entry = source[start:end] + "  ++accepted; return {1};\n}\n"
        current = source[source.index("  bool Current() const {"):source.index("  // Called only after the current stage")]
        continuation = source[source.index("  bool Continue() {"):source.index("  void Drain() {")]
        peers = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <memory>
#include <optional>
#include <utility>
namespace base {
struct UnguessableToken { int value=0; };
using OnceClosure=std::function<void()>;
template<class T> using OnceCallback=std::function<T>;
struct TimeTicks { int value; static TimeTicks Now() { return {0}; }
 friend bool operator>=(TimeTicks a,TimeTicks b) { return a.value>=b.value; } };
}
namespace mojom {
enum class Status { kBusy,kLimit,kUnsupported,kUnavailable,kChanged,kTimeout };
struct Limits { bool valid=true; };
using LimitsPtr=std::unique_ptr<Limits>;
}
struct Result { mojom::Status status; void* geometry=nullptr; std::optional<int> png; };
namespace capture { inline bool busy=false; bool Busy() { return busy; } }
struct View {
 bool showing=true; bool IsShowing() const { return showing; }
 int GetVisibleViewportSize() const { return 7; }
 float GetDeviceScaleFactor() const { return 2; }
};
namespace content {
struct RenderFrameHost {
 int count=1;
 std::optional<int> GetEmbeddingToken() const { return 1; }
 template<class F> void ForEachRenderFrameHost(F f) { for(int i=0;i<count;++i) f(this); }
};
struct WebContents {
 RenderFrameHost frame; View view;
 RenderFrameHost* GetPrimaryMainFrame() { return &frame; }
 View* GetRenderWidgetHostView() { return &view; }
};
}
bool ValidLimits(const mojom::Limits& limits) { return limits.valid; }
void InvalidLimits(const mojom::Limits*) {}
inline int accepted=0;
void Reply(base::OnceCallback<void(Result)> callback,Result result) { callback(result); }
struct Document {
 content::RenderFrameHost* frame;
 content::RenderFrameHost* AsRenderFrameHostIfValid() const { return frame; }
};
struct OperationPeer {
 content::WebContents* contents_;
 content::WebContents* web_contents() const { return contents_; }
 Document document_;
 int embedding_=1;
 View* view_;
 int viewport_=7;
 float device_scale_=2;
 bool callback_=true;
 base::TimeTicks deadline_{10};
 std::optional<mojom::Status> failure;
 int drained=0;
 void Fail(mojom::Status status) { failure=status;callback_=false; }
 void Drain() { ++drained; }
'''
        checks = r'''
int main() {
 content::WebContents contents;
 auto limits=[] { return std::make_unique<mojom::Limits>(); };
 std::optional<mojom::Status> reply;
 auto callback=[&](Result result) { reply=result.status; assert(!result.png); };
 contents.frame.count=2;
 CaptureDocumentPrototypeForTesting(&contents,limits(),{},callback);
 assert(reply==mojom::Status::kUnsupported && accepted==0);
 capture::busy=true;reply.reset();
 CaptureDocumentPrototypeForTesting(&contents,limits(),{},callback);
 assert(reply==mojom::Status::kBusy && accepted==0); // slot checked first
 capture::busy=false;contents.frame.count=1;reply.reset();
 CaptureDocumentPrototypeForTesting(&contents,limits(),{},callback);
 assert(!reply && accepted==1);
 OperationPeer operation{&contents,{&contents.frame},1,&contents.view};
 assert(operation.Current() && operation.Continue());
 contents.frame.count=2;
 assert(!operation.Current() && !operation.Continue());
 assert(operation.failure==mojom::Status::kChanged && operation.drained==1);
}
'''
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cpp = root / "frames.cc"
            cpp.write_text(peers + current + continuation + "};\n" + entry + checks)
            compiled = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-Wno-unused-parameter", "-Wno-missing-field-initializers", "-fsanitize=address,undefined",
                str(cpp), "-o", str(root / "frames"),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(root / "frames")], capture_output=True, text=True)
            self.assertEqual(executed.returncode, 0, executed.stderr)
