"""The page media bridge: an app-supplied script in bridged pages, and its messages (DEV-1144).

FairPlay in Chromium tabs needs a script in the page's main world before the page's own
code runs, and a private channel between that script and the app. `Packages/engine/Native/
page_media/` is copied to `components/arx_page_media`: the `PageMediaAgent` mojom interface
and its renderer side, created here for each outermost main frame next to the inspection
`Inspector` (so this overlay applies after `inspection_overlay.py`). The browser side is
`page_media_bridge.mm` in `chrome/browser/arx`: it prepares each cross-document commit of an
Arx page with the script when the origin is bridged, and binds `PageMediaHost` per document,
registered here in `ChromeContentBrowserClient::RegisterAssociatedInterfaceBindersForRenderFrameHost`
through the dependency-free `page_media_hooks.h`.

If an anchor changes, the build stops.
"""
import shutil

from .config import PACKAGE
from .overlay import replace_once

RENDERER_CLIENT = "chrome/renderer/chrome_content_renderer_client.cc"
RENDERER_BUILD = "chrome/renderer/BUILD.gn"
RECEIVER_BINDINGS = "chrome/browser/chrome_content_browser_client_receiver_bindings.cc"
COMPONENT = "components/arx_page_media"


def patches():
    # The renderer anchors end inspection_overlay.py's own insertions; this overlay adds after
    # them, never inside, so both stay repeatable.
    yield RENDERER_CLIENT, '#include "components/arx_inspection/inspector.h"\n#endif', (
        '#include "components/arx_inspection/inspector.h"\n#endif\n'
        '#if BUILDFLAG(IS_MAC)\n'
        '#include "components/arx_page_media/page_media_agent.h"\n'
        '#endif')
    yield RENDERER_CLIENT, "  new arx::inspection::Inspector(render_frame);\n#endif", (
        "  new arx::inspection::Inspector(render_frame);\n#endif\n"
        "#if BUILDFLAG(IS_MAC)\n"
        "  // DEV-1144: the page media bridge, top-level documents only.\n"
        "  if (render_frame->IsMainFrame() && !render_frame->IsInFencedFrameTree()) {\n"
        "    new arx::page_media::PageMediaAgent(render_frame);\n"
        "  }\n"
        "#endif")
    # Script may run here; DidCreateDocumentElement runs inside a ScriptForbiddenScope. Before
    # extensions' document_start scripts, as the page's own code comes after both.
    yield RENDERER_CLIENT, ("void ChromeContentRendererClient::RunScriptsAtDocumentStart(\n"
                            "    content::RenderFrame* render_frame) {\n"), (
        "void ChromeContentRendererClient::RunScriptsAtDocumentStart(\n"
        "    content::RenderFrame* render_frame) {\n"
        "#if BUILDFLAG(IS_MAC)\n"
        "  // DEV-1144: the page media bridge's script, in the main world.\n"
        "  arx::page_media::PageMediaAgent::RunAtDocumentStart(render_frame);\n"
        "#endif\n")
    yield RENDERER_BUILD, '  deps = [\n    "//components/arx_inspection:renderer",\n    ":process_state",', (
        '  deps = [\n    "//components/arx_inspection:renderer",\n    ":process_state",\n'
        '    "//components/arx_page_media:renderer",')
    yield RECEIVER_BINDINGS, '#include "chrome/browser/chrome_content_browser_client.h"\n', (
        '#include "chrome/browser/chrome_content_browser_client.h"\n'
        '#if BUILDFLAG(IS_MAC)\n'
        '#include "chrome/browser/arx/page_media_hooks.h"  // nogncheck\n'
        '#endif\n')
    yield RECEIVER_BINDINGS, (
        "        blink::AssociatedInterfaceRegistry& associated_registry) {\n"
        "  for (auto& ep : extra_parts_) {\n"
        "    ep->ExposeInterfacesToRendererForRenderFrameHost(render_frame_host,\n"), (
        "        blink::AssociatedInterfaceRegistry& associated_registry) {\n"
        "#if BUILDFLAG(IS_MAC)\n"
        "  // DEV-1144: the page media bridge's host, per bridged document.\n"
        "  arx::RegisterPageMediaBinders(render_frame_host, associated_registry);\n"
        "#endif\n"
        "  for (auto& ep : extra_parts_) {\n"
        "    ep->ExposeInterfacesToRendererForRenderFrameHost(render_frame_host,\n")


# The anchors inspection_overlay.py inserts; every other anchor is Chromium's own text.
INSPECTION_ANCHORS = (
    '#include "components/arx_inspection/inspector.h"\n#endif',
    "  new arx::inspection::Inspector(render_frame);\n#endif",
    '  deps = [\n    "//components/arx_inspection:renderer",\n    ":process_state",',
)


def upstream_patches():
    """The patches anchored on Chromium's own text, for fixtures that prepare a tree."""
    return [patch for patch in patches() if patch[1] not in INSPECTION_ANCHORS]


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
    destination = source / COMPONENT
    destination.mkdir(parents=True, exist_ok=True)
    for path in (PACKAGE / "Native/page_media").iterdir():
        if path.suffix in {".h", ".cc", ".mojom", ".gn"}:
            shutil.copy2(path, destination / path.name)
