"""Route only Arx-owned popup sources through their existing native host policy."""
from .overlay import replace_once


def apply(source):
    client = source / "chrome/browser/chrome_content_browser_client.cc"
    replace_once(client, '#include "chrome/browser/chrome_content_browser_client.h"',
                 '#include "chrome/browser/chrome_content_browser_client.h"\n'
                 '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/arx/engine_bridge.h"\n#endif')
    replace_once(client, '  const BlockedWindowParams blocked_params(\n',
                 '#if BUILDFLAG(IS_MAC)\n  arx::CapturePopupSource(opener);\n#endif\n'
                 '  const BlockedWindowParams blocked_params(\n')
    delegate = source / "chrome/browser/ui/blocked_content/chrome_popup_navigation_delegate.cc"
    replace_once(delegate, '#include "build/build_config.h"',
                 '#include "build/build_config.h"\n'
                 '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/arx/engine_bridge.h"\n#endif')
    replace_once(delegate,
                 '#if BUILDFLAG(IS_ANDROID)\n  TabModelList::HandlePopupNavigation(&params_);\n'
                 '#else\n  ::Navigate(&params_);\n#endif',
                 '#if BUILDFLAG(IS_MAC)\n'
                 '  if (!arx::NavigateBlockedPopup(&params_)) ::Navigate(&params_);\n'
                 '#elif BUILDFLAG(IS_ANDROID)\n  TabModelList::HandlePopupNavigation(&params_);\n'
                 '#else\n  ::Navigate(&params_);\n#endif')
    build = source / "chrome/browser/ui/blocked_content/BUILD.gn"
    text = build.read_text()
    marker = 'source_set("impl") {'
    if text.count(marker) != 1:
        raise ValueError("Popup delegate implementation target changed")
    start = text.index(marker)
    end = text.index("\n}\n", start)
    addition = '\n  if (is_mac) {\n    deps += [ "//chrome/browser/arx" ]\n  }\n'
    if addition not in text[start:end]:
        build.write_text(text[:end] + addition + text[end:])
