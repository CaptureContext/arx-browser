"""Let Arx offer a page's links for other apps to the app (ABI50, DEV-857).

`ExternalProtocolHandler::LaunchUrl` gains one offer after Chrome's block
policy, anti-flood check and Arx's source guard, and before its handler lookup,
"Open app?" dialog, remembered consent and OS launch. The rest of Chrome's path
becomes a continuation that runs unchanged when the app declines. The code lives
in `Native/engine_bridge.mm` behind `Native/external_link_bridge.h`.

Anchors are upstream lines only. The insertions sit outside the text that
`page_consent_overlay.py` adds to the same function, so neither applies twice.
"""
from .overlay import replace_once

HANDLER = "chrome/browser/external_protocol/external_protocol_handler.cc"


def patches():
    yield HANDLER, '#include "chrome/browser/external_protocol/external_protocol_handler.h"\n', \
        '#include "chrome/browser/external_protocol/external_protocol_handler.h"\n' \
        '#if BUILDFLAG(IS_MAC)\n' \
        '#include "chrome/browser/arx/external_link_bridge.h"  // nogncheck\n' \
        '#endif\n'
    # A request that already carries an owned handoff's completion (a direct
    # external child) keeps Chrome's path: dropping it would leak the handoff.
    yield HANDLER, """  // message loops.
  shell_integration::DefaultSchemeHandlerWorkerCallback callback =""", """  // message loops.
#if BUILDFLAG(IS_MAC)
  const bool arx_offers = !completion && arx::OffersExternalLinks(web_contents);
  // Chrome's exact-document guard moves into the worker's callback below; the
  // offer rechecks its own copy, so a stale subframe never reaches the app.
  base::RepeatingCallback<bool()> arx_source_guard = source_guard;
#else
  const bool arx_offers = false;
#endif
  shell_integration::DefaultSchemeHandlerWorkerCallback callback ="""
    yield HANDLER, """  // OnDefaultSchemeClientWorkerFinished().
  CreateShellWorker(escaped_url, g_external_protocol_handler_delegate)
      ->StartCheckIsDefaultAndGetDefaultClientName(std::move(callback));""", """  // OnDefaultSchemeClientWorkerFinished().
  base::OnceClosure chrome_path = base::BindOnce(
      [](const GURL& url, shell_integration::DefaultSchemeHandlerWorkerCallback callback) {
        CreateShellWorker(url, g_external_protocol_handler_delegate)
            ->StartCheckIsDefaultAndGetDefaultClientName(std::move(callback));
      },
      escaped_url, std::move(callback));
#if BUILDFLAG(IS_MAC)
  // Arx (ABI50, DEV-857): the app may take the link and ask itself; Chrome then
  // shows and launches nothing. Declined links continue here unchanged.
  if (arx_offers) {
    // The actual initiating origin: an opaque one's precursor is for display
    // only and never earns remembered consent.
    arx::OfferExternalLink(web_contents, escaped_url, initiating_origin,
                           page_transition, has_user_gesture, std::move(arx_source_guard),
                           std::move(chrome_path));
    return;
  }
#endif
  std::move(chrome_path).Run();"""


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
