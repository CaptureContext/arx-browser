"""Report a page's chrome:// links, which Blink refuses, to Arx (DEV-1193).

A web page's link, location change, window.open or remote-frame navigation to a
`chrome://` page stops in the renderer with "Not allowed to load local
resource": `SecurityOrigin::CanDisplay` fails, so the browser never hears of it.
At each of those three refusals, `ArxReportRefusedBrowserLink` (header-only,
copied to `third_party/blink/renderer/core/loader/`) reports the link through
the frame's BrowserInterfaceBroker while the frame has the person's activation.
The navigation stays refused.

`Native/browser_scheme_link/browser_scheme_link.mojom` is copied to
`third_party/blink/public/mojom/arx/` and listed in `mojom_platform`, which Blink
core and `//chrome/browser/arx` already depend on. `PopulateChromeFrameBinders`
binds it to `browser_scheme_link_bridge.mm`, which checks the browser's own
record of the activation, the scheme and the length, then offers the link to the
app through the external-link offer (ABI50), as any app's link is offered, with
a guard on the document that asked. App Links' built-in handler for Chrome's
pages takes it from there; no new export or ABI change.

arc:// links need none of this: Chromium doesn't know the scheme, so they reach
the external-link offer (ABI50) like any app's link.

If an anchor changes, the build stops.
"""
import shutil

from .config import PACKAGE
from .overlay import replace_once

MOJOM_BUILD = "third_party/blink/public/mojom/BUILD.gn"
MOJOM_DIRECTORY = "third_party/blink/public/mojom/arx"
HELPER_DIRECTORY = "third_party/blink/renderer/core/loader"
FRAME_LOADER = "third_party/blink/renderer/core/loader/frame_loader.cc"
CREATE_WINDOW = "third_party/blink/renderer/core/page/create_window.cc"
REMOTE_FRAME = "third_party/blink/renderer/core/frame/remote_frame.cc"
BINDERS = "chrome/browser/chrome_browser_interface_binders.cc"

HELPER_INCLUDE = '#include "third_party/blink/renderer/core/loader/arx_browser_scheme_link.h"\n'


def patches():
    yield MOJOM_BUILD, 'mojom("mojom_platform") {\n  generate_blink = true\n  generate_java = true\n  sources = [\n', (
        'mojom("mojom_platform") {\n  generate_blink = true\n  generate_java = true\n  sources = [\n'
        '    # Arx (DEV-1193): a page\'s refused chrome:// link.\n'
        '    "arx/browser_scheme_link.mojom",\n')

    # A link, location change or form in the frame.
    yield FRAME_LOADER, '#include "third_party/blink/renderer/core/loader/frame_loader.h"\n', (
        '#include "third_party/blink/renderer/core/loader/frame_loader.h"\n' + HELPER_INCLUDE)
    yield FRAME_LOADER, ("  if (!request.CanDisplay(url)) {\n"
                         "    request.GetOriginWindow()->AddConsoleMessage(\n"), (
        "  if (!request.CanDisplay(url)) {\n"
        "    // Arx (DEV-1193): the app may open its place for a chrome:// link.\n"
        "    ArxReportRefusedBrowserLink(request.GetOriginWindow()->GetFrame(), url);\n"
        "    request.GetOriginWindow()->AddConsoleMessage(\n")

    # window.open and target=_blank.
    yield CREATE_WINDOW, '#include "third_party/blink/renderer/core/page/create_window.h"\n', (
        '#include "third_party/blink/renderer/core/page/create_window.h"\n' + HELPER_INCLUDE)
    yield CREATE_WINDOW, ("  if (!opener_window.GetSecurityOrigin()->CanDisplay(url)) {\n"
                          "    opener_window.AddConsoleMessage("), (
        "  if (!opener_window.GetSecurityOrigin()->CanDisplay(url)) {\n"
        "    // Arx (DEV-1193): the app may open its place for a chrome:// link.\n"
        "    ArxReportRefusedBrowserLink(&opener_frame, url);\n"
        "    opener_window.AddConsoleMessage(")

    # A frame navigating another process's frame, such as a cross-site iframe's link with
    # target=_top.
    yield REMOTE_FRAME, '#include "third_party/blink/renderer/core/frame/remote_frame.h"\n', (
        '#include "third_party/blink/renderer/core/frame/remote_frame.h"\n' + HELPER_INCLUDE)
    yield REMOTE_FRAME, ("  if (!frame_request.CanDisplay(url)) {\n"
                         "    window->AddConsoleMessage("), (
        "  if (!frame_request.CanDisplay(url)) {\n"
        "    // Arx (DEV-1193): the app may open its place for a chrome:// link.\n"
        "    ArxReportRefusedBrowserLink(window->GetFrame(), url);\n"
        "    window->AddConsoleMessage(")

    # After build_config.h, which defines BUILDFLAG; the file's own header doesn't.
    yield BINDERS, '#include "build/build_config.h"\n', (
        '#include "build/build_config.h"\n'
        '#if BUILDFLAG(IS_MAC)\n'
        '#include "chrome/browser/arx/browser_scheme_link_hooks.h"  // nogncheck\n'
        '#include "third_party/blink/public/mojom/arx/browser_scheme_link.mojom.h"\n'
        '#endif\n')
    yield BINDERS, ("    content::RenderFrameHost* render_frame_host) {\n"
                    "  map->Add<glic::mojom::WebClientHandler>(&glic::BindGlicWebClientHandler);\n"), (
        "    content::RenderFrameHost* render_frame_host) {\n"
        "#if BUILDFLAG(IS_MAC)\n"
        "  // Arx (DEV-1193): a page's chrome:// link that Blink refused.\n"
        "  map->Add<blink::mojom::ArxBrowserSchemeLinkHost>(&arx::BindBrowserSchemeLinkHost);\n"
        "#endif\n"
        "  map->Add<glic::mojom::WebClientHandler>(&glic::BindGlicWebClientHandler);\n")


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
    native = PACKAGE / "Native/browser_scheme_link"
    mojom = source / MOJOM_DIRECTORY
    mojom.mkdir(parents=True, exist_ok=True)
    shutil.copy2(native / "browser_scheme_link.mojom", mojom / "browser_scheme_link.mojom")
    shutil.copy2(native / "arx_browser_scheme_link.h", source / HELPER_DIRECTORY / "arx_browser_scheme_link.h")
