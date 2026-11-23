"""Execute production RuntimeAPI ownership admission, completion and shutdown."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method
from Scripts.engine import extension_navigation_overlay


class ExtensionRuntimeOptionsTests(unittest.TestCase):
    def test_exact_extension_profile_and_physical_work_survive_publication_and_reply(self):
        native = (PACKAGE / "Native/extensions_bridge.mm").read_text()
        source = (Path(__file__).parent / "fixtures/extension_runtime_options.cc").read_text()
        source = source.replace("// OPEN_RUNTIME", method(native, "  void OpenRuntimeOptions("))
        self.run_cpp(source)

    def test_embedded_dispatch_owns_refusal_and_empty_hook_preserves_chrome(self):
        replacements = list(extension_navigation_overlay.patches())
        changed = next(after for _, _, after in replacements if "auto opener = EmbeddedOptionsPageOpener()" in after)
        prefix = changed.split("  if (!extensions::OptionsPageInfo::HasOptionsPage(extension))", 1)[0]
        source = r'''
#include <cassert>
#include <functional>
#include <utility>
namespace content {struct BrowserContext {};}
namespace extensions {struct Extension {};}
namespace base {template<class>struct OnceCallback;
template<class R,class...A>struct OnceCallback<R(A...)> {
 std::function<R(A...)> f;template<class F>OnceCallback(F fn):f(std::move(fn)){}
 R Run(A... args){auto taken=std::move(f);return taken(std::forward<A>(args)...);}
};}
struct Opener {
 std::function<void(const extensions::Extension*,content::BrowserContext*,base::OnceCallback<void(bool)>)> f;
 explicit operator bool()const{return bool(f);}
 void Run(const extensions::Extension* e,content::BrowserContext* c,base::OnceCallback<void(bool)> reply){f(e,c,std::move(reply));}
};
Opener& EmbeddedOptionsPageOpener(){static Opener opener;return opener;}
struct Host {int fallback=0;void OpenOptionsPage(const extensions::Extension* extension,content::BrowserContext* browser_context,
// DISPATCH
 ++fallback;std::move(callback).Run(true);
}};
int main(){Host host;extensions::Extension extension;content::BrowserContext context;int replies=0;
 host.OpenOptionsPage(&extension,&context,[&](bool value){assert(value);++replies;});assert(replies==1&&host.fallback==1);
 EmbeddedOptionsPageOpener().f=[&](auto* e,auto* c,auto reply){assert(e==&extension&&c==&context);EmbeddedOptionsPageOpener().f={};std::move(reply).Run(false);};
 host.OpenOptionsPage(&extension,&context,[&](bool value){assert(!value);++replies;});assert(replies==2&&host.fallback==1);
}
'''
        self.run_cpp(source.replace("// DISPATCH", prefix))

    def run_cpp(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                str(root / "test.cc"), "-o", str(root / "test"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
